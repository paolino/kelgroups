export const setExitCode = (code) => () => {
  process.exitCode = code;
};
