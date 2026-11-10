// Sends an uploaded build to external TestFlight testers: What to Test, the group, beta review.
//
//   security find-generic-password -s <service> -w | \
//     ASC_KEY_ID=… ASC_ISSUER_ID=… node scripts/asc-testflight.mjs dev.gudo.app <build> "Public Beta" notes.txt
//
// Reads the API key (.p8 contents, base64) on stdin. Waits up to an hour for the build to process.
import { createPrivateKey, createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';

const [bundleIdentifier, buildNumber, groupName, notesPath] = process.argv.slice(2);
if (!notesPath) throw new Error('usage: asc-testflight.mjs <bundle-id> <build> <group> <notes-file>');
const whatToTest = readFileSync(notesPath, 'utf8').trim();
const privateKey = createPrivateKey(Buffer.from(readFileSync(0, 'utf8').trim(), 'base64').toString());

function bearerToken() {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const issuedAt = Math.floor(Date.now() / 1000);
  const unsigned = `${encode({ alg: 'ES256', kid: process.env.ASC_KEY_ID, typ: 'JWT' })}.${encode({
    iss: process.env.ASC_ISSUER_ID,
    iat: issuedAt,
    exp: issuedAt + 600,
    aud: 'appstoreconnect-v1',
  })}`;
  const signer = createSign('SHA256');
  signer.update(unsigned);
  return `${unsigned}.${signer.sign({ key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}

async function api(method, path, body) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${bearerToken()}`, 'Content-Type': 'application/json' },
    body: body && JSON.stringify(body),
  });
  if (response.status === 204) return {};
  const payload = await response.json();
  if (!response.ok) throw new Error(`${method} ${path}: ${JSON.stringify(payload.errors)}`);
  return payload;
}

const app = (await api('GET', `/v1/apps?filter[bundleId]=${bundleIdentifier}`)).data
  .find((candidate) => candidate.attributes.bundleId === bundleIdentifier);
if (!app) throw new Error(`no app ${bundleIdentifier}`);
const group = (await api('GET', `/v1/apps/${app.id}/betaGroups?limit=50`)).data
  .find((candidate) => candidate.attributes.name === groupName);
if (!group) throw new Error(`no TestFlight group ${groupName}`);

let build;
for (let attempt = 0; attempt < 120; attempt += 1) {
  build = (await api('GET', `/v1/builds?filter[app]=${app.id}&filter[version]=${buildNumber}&limit=1`)).data[0];
  const state = build?.attributes.processingState;
  if (state === 'VALID') break;
  if (state === 'FAILED' || state === 'INVALID') throw new Error(`build ${buildNumber} is ${state}`);
  console.log(`build ${buildNumber}: ${state ?? 'not visible yet'}`);
  await new Promise((resolve) => setTimeout(resolve, 30_000));
}
if (build?.attributes.processingState !== 'VALID') throw new Error(`build ${buildNumber} did not finish processing`);

const localizations = (await api('GET', `/v1/builds/${build.id}/betaBuildLocalizations`)).data;
if (localizations.length === 0) {
  await api('POST', '/v1/betaBuildLocalizations', {
    data: {
      type: 'betaBuildLocalizations',
      attributes: { locale: 'en-US', whatsNew: whatToTest },
      relationships: { build: { data: { type: 'builds', id: build.id } } },
    },
  });
}
for (const localization of localizations) {
  await api('PATCH', `/v1/betaBuildLocalizations/${localization.id}`, {
    data: { type: 'betaBuildLocalizations', id: localization.id, attributes: { whatsNew: whatToTest } },
  });
}
console.log('what to test is set');

await api('POST', `/v1/betaGroups/${group.id}/relationships/builds`, { data: [{ type: 'builds', id: build.id }] });
console.log(`build ${buildNumber} is in ${groupName}`);

const reviews = (await api('GET', `/v1/betaAppReviewSubmissions?filter[build]=${build.id}`)).data;
if (reviews.length === 0) {
  await api('POST', '/v1/betaAppReviewSubmissions', {
    data: { type: 'betaAppReviewSubmissions', relationships: { build: { data: { type: 'builds', id: build.id } } } },
  });
}
console.log(`build ${buildNumber} is in beta review`);
