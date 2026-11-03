// Fetches (or creates) App Store Connect provisioning profiles and installs them for Xcode.
//
//   security find-generic-password -s <service> -w | \
//     ASC_KEY_ID=… ASC_ISSUER_ID=… node scripts/asc-profiles.mjs IOS_APP_STORE DISTRIBUTION \
//       dev.gudo.app="Gudo App Store" dev.gudo.app.notification-service="Gudo Notifications App Store"
//
// Reads the API key (.p8 contents, base64) on stdin. Prints `bundle-id=profile-name` per line.
import { createPrivateKey, createSign } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const [profileType, certificateType, ...requests] = process.argv.slice(2);
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
  const payload = await response.json();
  if (!response.ok) throw new Error(`${method} ${path}: ${JSON.stringify(payload.errors)}`);
  return payload;
}

const now = new Date();
const certificates = (await api('GET', `/v1/certificates?filter[certificateType]=${certificateType}&limit=200`)).data
  .filter((certificate) => new Date(certificate.attributes.expirationDate) > now);
if (certificates.length === 0) throw new Error(`no valid ${certificateType} certificate`);

const profilesDirectory = join(homedir(), 'Library/Developer/Xcode/UserData/Provisioning Profiles');
mkdirSync(profilesDirectory, { recursive: true });

for (const request of requests) {
  const [bundleIdentifier, profileName] = request.split('=');
  const bundle = (await api('GET', `/v1/bundleIds?filter[identifier]=${bundleIdentifier}`)).data
    .find((candidate) => candidate.attributes.identifier === bundleIdentifier);
  if (!bundle) throw new Error(`bundle ID ${bundleIdentifier} is not registered`);

  const existing = (await api('GET', `/v1/profiles?filter[name]=${encodeURIComponent(profileName)}&limit=200`)).data
    .find((profile) => profile.attributes.name === profileName && profile.attributes.profileState === 'ACTIVE');
  const profile = existing ?? (await api('POST', '/v1/profiles', {
    data: {
      type: 'profiles',
      attributes: { name: profileName, profileType },
      relationships: {
        bundleId: { data: { type: 'bundleIds', id: bundle.id } },
        certificates: { data: certificates.map((certificate) => ({ type: 'certificates', id: certificate.id })) },
      },
    },
  })).data;

  writeFileSync(
    join(profilesDirectory, `${profile.attributes.uuid}.mobileprovision`),
    Buffer.from(profile.attributes.profileContent, 'base64'),
  );
  console.log(`${bundleIdentifier}=${profileName}`);
}
