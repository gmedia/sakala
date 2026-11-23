// Opens a sleeping project in a real browser and checks that the agent's waiting
// page wakes it through this installation's API, the way a visitor does. Run by
// tests/install-e2e.sh (phase sleep), with the edge's local CA trusted through the
// NSS database in $HOME, so certificate errors stay errors.
//
// Environment:
//   PROJECT_URL      https://<slug>.run.<domain>/, sleeping when this starts
//   WAKE_URL         https://api.<domain>/api/v1/public/projects/<slug>/wake
//   CHROME_CHANNEL   'chrome' to use the installed Google Chrome; empty for
//                    Playwright's own Chromium
//
// Passes when:
//   - the first load of PROJECT_URL answers 503, the agent's waiting page,
//   - the page sends POST WAKE_URL and that request does not fail,
//   - a later load of PROJECT_URL, which the page starts by itself, answers 200
//     within the page's own wait (120 seconds), with no click or reload by the test.

import { chromium } from 'playwright-core';

const projectUrl = process.env.PROJECT_URL;
const wakeUrl = process.env.WAKE_URL;
if (!projectUrl || !wakeUrl) {
	console.error('PROJECT_URL and WAKE_URL are required.');
	process.exit(2);
}

// The waiting page gives up after 120 seconds; a little more covers the last reload.
const WAKE_TIMEOUT_MS = 150_000;
const POLL_MS = 1_000;

const problems = [];
const loads = [];
const wakeRequests = [];
const failed = [];

const browser = await chromium.launch({ channel: process.env.CHROME_CHANNEL || undefined });
try {
	const page = await browser.newPage();
	page.on('response', (response) => {
		const request = response.request();
		if (request.isNavigationRequest() && request.frame() === page.mainFrame()) {
			loads.push({ status: response.status(), at: Date.now() });
		}
	});
	page.on('request', (request) => {
		if (request.url() === wakeUrl) wakeRequests.push(request.method());
	});
	page.on('requestfailed', (request) => {
		failed.push(`${request.method()} ${request.url()}: ${request.failure()?.errorText}`);
	});

	const started = Date.now();
	const first = await page.goto(projectUrl, { waitUntil: 'load', timeout: 60_000 });
	if (!first || first.status() !== 503) {
		problems.push(`the first load of ${projectUrl} answered ${first ? first.status() : 'nothing'}, expected 503 (the waiting page)`);
	}

	while (Date.now() - started < WAKE_TIMEOUT_MS && !loads.some((load) => load.status === 200)) {
		await page.waitForTimeout(POLL_MS);
	}
	const woke = loads.find((load) => load.status === 200);
	if (!woke) problems.push(`${projectUrl} did not answer 200 within ${WAKE_TIMEOUT_MS / 1000} seconds`);
	if (!wakeRequests.includes('POST')) problems.push(`the waiting page did not send POST ${wakeUrl}`);
	const wakeFailures = failed.filter((line) => line.includes(wakeUrl));
	if (wakeFailures.length > 0) problems.push(`the wake request failed: ${wakeFailures.join('; ')}`);

	console.log(`browser: ${browser.version()}`);
	console.log(`loads of the project page: ${loads.map((load) => load.status).join(', ') || 'none'}`);
	console.log(`wake requests: ${wakeRequests.join(', ') || 'none'}`);
	if (woke) console.log(`awake after ${Math.round((woke.at - started) / 1000)} seconds`);
	if (failed.length > 0) console.log(`failed requests: ${failed.join('; ')}`);
} finally {
	await browser.close();
}

if (problems.length > 0) {
	for (const problem of problems) console.error(`FAIL ${problem}`);
	process.exit(1);
}
console.log(`ok   the waiting page woke the project through ${new URL(wakeUrl).origin}`);
