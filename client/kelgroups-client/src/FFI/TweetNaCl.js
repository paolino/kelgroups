import nacl from "tweetnacl";

export const generateKeyPairImpl = () => {
  const kp = nacl.sign.keyPair();
  return { publicKey: kp.publicKey, secretKey: kp.secretKey };
};

export const signImpl = (message) => (secretKey) => {
  return nacl.sign.detached(message, secretKey);
};

export const verifyImpl = (message) => (signature) => (publicKey) => {
  return nacl.sign.detached.verify(message, signature, publicKey);
};
