export const lookupEnvImpl = (k) => () => {
  const v = process.env[k];
  return v === undefined ? null : v;
};
