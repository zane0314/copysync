/// Public defaults are safe examples. Production builds must inject their own
/// endpoints with --dart-define.
const defaultBaseUrl = String.fromEnvironment(
  'COPYSYNC_BASE_URL',
  defaultValue: 'https://copy.example.com',
);

const updateBaseUrl = String.fromEnvironment(
  'COPYSYNC_UPDATE_BASE_URL',
  defaultValue: defaultBaseUrl,
);
