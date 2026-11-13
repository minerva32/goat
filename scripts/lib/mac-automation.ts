export const MAC_AUTOMATION = {
  entitlement: `
    <key>com.apple.security.automation.apple-events</key>
    <true/>`,
  usageDescription:
    "GOAT sends commands to other apps when you use computer control or commands run by coding agents.",
} as const;
