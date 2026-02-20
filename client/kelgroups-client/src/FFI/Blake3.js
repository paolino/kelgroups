import blakejs from "blakejs";

export const hashImpl = (bytes) => new Uint8Array(blakejs.blake2b(bytes, null, 32));
