export const length = (arr) => arr.length;

export const zeros = (n) => new Uint8Array(n);

export const concat = (a) => (b) => {
  const result = new Uint8Array(a.length + b.length);
  result.set(a, 0);
  result.set(b, a.length);
  return result;
};

export const drop = (n) => (arr) => arr.slice(n);

export const slice = (start) => (end) => (arr) => arr.slice(start, end);
