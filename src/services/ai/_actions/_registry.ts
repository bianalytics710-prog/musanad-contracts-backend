/**
 * Handler registry. Maps action_registry.handler_id (DB catalog string) to
 * its in-process async function. The chat orchestrator looks up here when
 * dispatching a resolver tool_call or executing a confirmed proposal.
 *
 * Adding a new action:
 *   1. Insert a row in action_registry (DB seed migration).
 *   2. Implement the handler function under _actions/.
 *   3. Add a key here mapping handler_id → fn.
 *
 * That's it — no controller/route changes required (the orchestrator's
 * /chat/ask + /chat/execute endpoints are generic).
 */
import type { ChatHandlerContext, ChatProposalReceipt } from '../../../types/chat-orchestrator.types';
import { resolverHandlers } from './_resolvers';
import { requestSimilarContractHandler } from './request-similar-contract.handler';
import { addToMyQueueHandler } from './add-to-my-queue.handler';

export type ResolverHandler = (
  args: Record<string, unknown>,
  ctx: ChatHandlerContext,
) => Promise<Record<string, unknown>>;

export type WriteActionHandler = (
  args: Record<string, unknown>,
  ctx: ChatHandlerContext,
) => Promise<ChatProposalReceipt>;

export const RESOLVER_REGISTRY: Record<string, ResolverHandler> = {
  lookup_contract_by_number: resolverHandlers.lookup_contract_by_number as ResolverHandler,
  find_drafters: resolverHandlers.find_drafters as ResolverHandler,
  find_users: resolverHandlers.find_users as ResolverHandler,
  find_parties: resolverHandlers.find_parties as ResolverHandler,
};

export const WRITE_ACTION_REGISTRY: Record<string, WriteActionHandler> = {
  request_similar_contract: requestSimilarContractHandler,
  add_to_my_queue: addToMyQueueHandler,
};

export function getResolverHandler(handlerId: string): ResolverHandler | undefined {
  return RESOLVER_REGISTRY[handlerId];
}

export function getWriteActionHandler(handlerId: string): WriteActionHandler | undefined {
  return WRITE_ACTION_REGISTRY[handlerId];
}
