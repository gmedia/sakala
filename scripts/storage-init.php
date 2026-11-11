<?php

declare(strict_types=1);

/*
 * One-shot bucket bootstrap for the API `avatars` disk, executed through
 * `php artisan tinker --execute` inside the sakala-api image (see the
 * storage-init service in compose.yaml). It is idempotent: it creates the
 * bucket when missing and (re)applies an anonymous read policy limited to the
 * avatars/ prefix, which is what Storage::disk('avatars')->url() relies on.
 *
 * Credentials come from the mounted API environment; nothing is printed
 * beyond bucket name and outcome.
 */

use Illuminate\Support\Facades\Storage;

$disk = Storage::disk('avatars');
$bucket = (string) config('filesystems.disks.avatars.bucket');

if ($bucket === '') {
    fwrite(STDERR, "AWS_BUCKET is not configured for the avatars disk.\n");
    exit(1);
}

/** @var \Aws\S3\S3Client $client */
$client = $disk->getClient();

if ($client->doesBucketExistV2($bucket)) {
    echo "Bucket {$bucket} already exists.\n";
} else {
    $client->createBucket(['Bucket' => $bucket]);
    echo "Bucket {$bucket} created.\n";
}

$policy = [
    'Version' => '2012-10-17',
    'Statement' => [[
        'Sid' => 'SakalaPublicAvatarRead',
        'Effect' => 'Allow',
        'Principal' => '*',
        'Action' => ['s3:GetObject'],
        'Resource' => ["arn:aws:s3:::{$bucket}/avatars/*"],
    ]],
];

$client->putBucketPolicy([
    'Bucket' => $bucket,
    'Policy' => json_encode($policy, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES),
]);

echo "Anonymous read policy applied to {$bucket}/avatars/*.\n";
