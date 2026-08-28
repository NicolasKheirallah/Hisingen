import {
  createPrivateKey,
  createPublicKey,
  timingSafeEqual,
} from 'node:crypto';
import { readFileSync } from 'node:fs';

const PKCS8_ED25519_SEED_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');

function decodeBase64(value, label) {
  const normalized = value.trim();
  if (!normalized || !/^[A-Za-z0-9+/]+={0,2}$/.test(normalized) || normalized.length % 4 !== 0) {
    throw new Error(`${label} is not valid base64`);
  }
  return Buffer.from(normalized, 'base64');
}

function publicKeyFromSparkleSecret(secret) {
  if (secret.length === 96) {
    return secret.subarray(64);
  }
  if (secret.length !== 32) {
    throw new Error(`Sparkle private key must decode to 32 or 96 bytes, got ${secret.length}`);
  }

  const privateKey = createPrivateKey({
    key: Buffer.concat([PKCS8_ED25519_SEED_PREFIX, secret]),
    format: 'der',
    type: 'pkcs8',
  });
  const publicDER = createPublicKey(privateKey).export({ format: 'der', type: 'spki' });
  return publicDER.subarray(-32);
}

function verifyKeyPair(publicKeyBase64, privateKeyBase64) {
  const configuredPublicKey = decodeBase64(publicKeyBase64, 'SPARKLE_PUBLIC_ED_KEY');
  if (configuredPublicKey.length !== 32) {
    throw new Error(`SPARKLE_PUBLIC_ED_KEY must decode to 32 bytes, got ${configuredPublicKey.length}`);
  }
  const privateSecret = decodeBase64(privateKeyBase64, 'Sparkle private key file');
  const derivedPublicKey = publicKeyFromSparkleSecret(privateSecret);
  if (!timingSafeEqual(configuredPublicKey, derivedPublicKey)) {
    throw new Error('SPARKLE_PUBLIC_ED_KEY does not match SPARKLE_PRIVATE_ED_KEY');
  }
}

if (process.argv[2] === '--self-test') {
  const seed = Buffer.from(Array.from({ length: 32 }, (_, index) => index + 1));
  const publicKey = publicKeyFromSparkleSecret(seed);
  verifyKeyPair(publicKey.toString('base64'), seed.toString('base64'));
  const legacySecret = Buffer.concat([Buffer.alloc(64, 0x5a), publicKey]);
  verifyKeyPair(publicKey.toString('base64'), legacySecret.toString('base64'));

  const mismatch = Buffer.from(publicKey);
  mismatch[0] ^= 0xff;
  try {
    verifyKeyPair(mismatch.toString('base64'), seed.toString('base64'));
    throw new Error('Mismatched key-pair negative control unexpectedly passed');
  } catch (error) {
    if (!String(error.message).includes('does not match')) throw error;
  }

  try {
    verifyKeyPair('AQ==', seed.toString('base64'));
    throw new Error('Malformed public-key negative control unexpectedly passed');
  } catch (error) {
    if (!String(error.message).includes('must decode to 32 bytes')) throw error;
  }

  console.log('sparkle-keypair-self-test-passed');
} else {
  const privateKeyPath = process.argv[2];
  if (!privateKeyPath || !process.env.SPARKLE_PUBLIC_ED_KEY) {
    throw new Error('Usage: SPARKLE_PUBLIC_ED_KEY=... node Scripts/verify-sparkle-keypair.mjs PRIVATE_KEY_FILE');
  }
  verifyKeyPair(process.env.SPARKLE_PUBLIC_ED_KEY, readFileSync(privateKeyPath, 'utf8'));
  console.log('sparkle-keypair-verified');
}
