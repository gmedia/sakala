// Opens the installed Console in a real browser and checks that it calls the API
// of this installation, not one baked into the image. Run by tests/install-e2e.sh,
// with the edge's local CA trusted through the NSS database in $HOME, so
// certificate errors stay errors.
//
// Environment:
//   APP_ORIGIN   https://app.<domain>
//   API_ORIGIN   https://api.<domain>
//   CHROME_CHANNEL   'chrome' to use the installed Google Chrome; empty for
//                    Playwright's own Chromium
//
// Passes when, after opening /projects without a session:
//   - the Console asked API_ORIGIN for /api/v1/auth/user and the real API answered,
//   - the Console then showed /login (it read that answer, so CORS allowed it),
//   - every request went to APP_ORIGIN or API_ORIGIN, none to another host,
//   - no request to API_ORIGIN failed and no Content-Security-Policy violation was reported.

import { chromium } from 'playwright-core';

const appOrigin = process.env.APP_ORIGIN;
const apiOrigin = process.env.API_ORIGIN;
if (!appOrigin || !apiOrigin) {
	console.error('APP_ORIGIN and API_ORIGIN are required.');
	process.exit(2);
}

const problems = [];
const apiResponses = [];
const otherOrigins = new Set();
const failed = [];
const cspViolations = [];

const browser = await chromium.launch({ channel: process.env.CHROME_CHANNEL || undefined });
try {
	const page = await browser.newPage();
	page.on('request', (request) => {
		const url = new URL(request.url());
		if (!url.protocol.startsWith('http') && !url.protocol.startsWith('ws')) return;
		const origin = url.origin.replace(/^ws/, 'http');
		if (origin !== appOrigin && origin !== apiOrigin) otherOrigins.add(url.origin);
	});
	page.on('response', (response) => {
		const url = new URL(response.url());
		if (url.origin === apiOrigin && url.pathname.startsWith('/api/')) {
			apiResponses.push(`${response.request().method()} ${url.pathname} ${response.status()}`);
		}
	});
	page.on('requestfailed', (request) => {
		failed.push(`${request.method()} ${request.url()}: ${request.failure()?.errorText}`);
	});
	page.on('console', (message) => {
		if (/Content Security Policy/i.test(message.text())) cspViolations.push(message.text());
	});

	const response = await page.goto(`${appOrigin}/projects`, { waitUntil: 'load', timeout: 60_000 });
	if (!response || response.status() !== 200) {
		problems.push(`${appOrigin}/projects answered ${response ? response.status() : 'nothing'}, expected 200`);
	}
	try {
		await page.waitForURL(/\/login(\?|$)/, { timeout: 30_000 });
	} catch {
		problems.push(`the Console did not move to /login without a session; it shows ${page.url()}`);
	}
	await page.waitForLoadState('networkidle', { timeout: 15_000 }).catch(() => {});

	if (!apiResponses.some((line) => line.startsWith('GET /api/v1/auth/user '))) {
		problems.push(`no answer from ${apiOrigin}/api/v1/auth/user reached the Console`);
	}
	if (otherOrigins.size > 0) problems.push(`requests to other origins: ${[...otherOrigins].join(', ')}`);
	const apiFailures = failed.filter((line) => line.includes(apiOrigin));
	if (apiFailures.length > 0) problems.push(`failed API requests: ${apiFailures.join('; ')}`);
	if (cspViolations.length > 0) problems.push(`Content-Security-Policy violations: ${cspViolations.join('; ')}`);

	console.log(`browser: ${browser.version()}`);
	console.log(`API answers seen by the Console: ${apiResponses.join(', ') || 'none'}`);
	console.log(`final page: ${page.url()}`);
	if (failed.length > 0) console.log(`failed requests: ${failed.join('; ')}`);
} finally {
	await browser.close();
}

if (problems.length > 0) {
	for (const problem of problems) console.error(`FAIL ${problem}`);
	process.exit(1);
}
console.log(`ok   the Console in a browser calls ${apiOrigin} and nothing else`);
