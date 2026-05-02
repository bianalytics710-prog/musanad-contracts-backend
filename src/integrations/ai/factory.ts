/**
 * Re-export the singleton accessor. Some feature modules will import this
 * path explicitly to make the dispatch decision visible at the call site.
 */
export { getAIProvider } from './index';
export type { AIProvider, AIOpts, AIResponse } from './index';
