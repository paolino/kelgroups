const encoder = new TextEncoder();
const decoder = new TextDecoder();

export const encodeUtf8 = (str) => encoder.encode(str);

export const decodeUtf8 = (bytes) => decoder.decode(bytes);
