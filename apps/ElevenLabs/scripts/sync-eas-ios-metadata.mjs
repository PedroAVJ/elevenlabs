import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const values = args.filter((arg) => arg !== '--dry-run');
const [buildNumber, suppliedAppVersion] = values;

if (!/^\d+(?:\.\d+){0,2}$/.test(buildNumber ?? '')) {
  throw new Error(`Invalid EAS iOS build number: ${buildNumber ?? '<missing>'}`);
}

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(scriptDirectory, '..');
const appConfig = JSON.parse(
  fs.readFileSync(path.join(projectRoot, 'app.json'), 'utf8'),
);
const appVersion = suppliedAppVersion ?? appConfig.expo?.version;
const privateBetaApiKey = process.env.ELEVENLABS_PRIVATE_BETA_API_KEY?.trim();

if (!/^\d+(?:\.\d+){0,2}$/.test(appVersion ?? '')) {
  throw new Error(`Invalid Expo iOS app version: ${appVersion ?? '<missing>'}`);
}

if (!privateBetaApiKey) {
  throw new Error(
    'Missing ELEVENLABS_PRIVATE_BETA_API_KEY in the production EAS environment',
  );
}

const projectFile = path.join(
  projectRoot,
  'ios',
  'ElevenLabs.xcodeproj',
  'project.pbxproj',
);
const plistFiles = [
  path.join(projectRoot, 'ios', 'ElevenLabs', 'Info.plist'),
  path.join(projectRoot, 'ios', 'ElevenLabsKeyboard', 'Info.plist'),
  path.join(projectRoot, 'ios', 'ElevenLabsLiveActivity', 'Info.plist'),
];

function escapeXml(value) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
}

function replacePlistString(contents, key, value) {
  const pattern = new RegExp(
    `(<key>${key}</key>\\s*<string>)[\\s\\S]*?(</string>)`,
  );
  if (!pattern.test(contents)) {
    throw new Error(`Missing ${key} in an iOS Info.plist`);
  }
  return contents.replace(pattern, `$1${escapeXml(value)}$2`);
}

let project = fs.readFileSync(projectFile, 'utf8');
const buildSettingMatches = project.match(/CURRENT_PROJECT_VERSION = [^;]+;/g) ?? [];
const versionSettingMatches = project.match(/MARKETING_VERSION = [^;]+;/g) ?? [];

if (buildSettingMatches.length < 3 || versionSettingMatches.length < 3) {
  throw new Error('Expected version settings for the app and both extensions');
}

project = project.replace(
  /CURRENT_PROJECT_VERSION = [^;]+;/g,
  `CURRENT_PROJECT_VERSION = ${buildNumber};`,
);
project = project.replace(
  /MARKETING_VERSION = [^;]+;/g,
  `MARKETING_VERSION = ${appVersion};`,
);

if (!dryRun) {
  fs.writeFileSync(projectFile, project);
}

for (const plistFile of plistFiles) {
  let plist = fs.readFileSync(plistFile, 'utf8');
  plist = replacePlistString(plist, 'CFBundleVersion', buildNumber);
  plist = replacePlistString(plist, 'CFBundleShortVersionString', appVersion);

  if (plistFile.endsWith(path.join('ElevenLabs', 'Info.plist'))) {
    const sentryDsn = process.env.ELEVENLABS_SENTRY_DSN;
    if (sentryDsn) {
      plist = replacePlistString(plist, 'SentryDSN', sentryDsn);
    }
    plist = replacePlistString(
      plist,
      'ElevenLabsPrivateBetaAPIKey',
      privateBetaApiKey,
    );
  }

  if (!dryRun) {
    fs.writeFileSync(plistFile, plist);
  }
}

const sentryState = process.env.ELEVENLABS_SENTRY_DSN ? 'enabled' : 'disabled';
const mode = dryRun ? 'Validated' : 'Synchronized';
console.log(
  `${mode} ElevenLabs ${appVersion} (${buildNumber}) across three iOS bundles; observability ${sentryState}; private-beta credential configured.`,
);
