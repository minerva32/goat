import type { SettingsAccess, SettingsKey } from "./settingsAccess.ts";

const agent = { access: "agent" } as const;

export const PERSONAL_SETTINGS_ACCESS_OVERRIDES = {
  mcpServers: agent,
  enableAgentMemoryAccess: agent,
  agentMemoryLimitGiB: agent,
  agentWorkspaceAccess: agent,
  agentTerminalAccess: agent,
  enableAgentBrowserAccess: agent,
  blockedBrowserHosts: agent,
  projectAgentBrowserAccessOverrides: agent,
  defaultRuntimeMode: agent,
  projectSettingsOverrides: agent,
  enableAgentDeviceAccess: agent,
  enableDeviceSupport: agent,
  computerUseKeepTypedText: agent,
  cuaFullAccessAutoAdmit: agent,
  cuaMovePointer: agent,
  cuaStrictInputGuards: agent,
  cuaAllowedApps: agent,
  cuaDeniedApps: agent,
  deviceHosts: agent,
  goatclaw: agent,
  pen: agent,
  guestSharingEnabled: agent,
  observability: agent,
} as const satisfies Partial<Record<SettingsKey, SettingsAccess>>;
