export type ResponseAt = number | null

declare module 'claude-code' {
  interface PluginState {
    'cache-handoff': { lastResponseAt: ResponseAt; isBusy: boolean }
  }
}
