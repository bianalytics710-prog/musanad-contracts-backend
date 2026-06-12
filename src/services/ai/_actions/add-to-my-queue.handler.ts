/**
 * Write-action handler: add_to_my_queue.
 *
 * Self-assigned manual work_order entry. Wraps fn_work_order_create_manual,
 * the same fn the REST endpoint /work-orders/manual calls.
 */
import { z } from 'zod';
import { db } from '../../../database/client';
import { ForbiddenError } from '../../../utils/errors.util';
import type { ChatHandlerContext, ChatProposalReceipt } from '../../../types/chat-orchestrator.types';

const paramsSchema = z.object({
  requestType: z.enum(['contract_draft_request', 'contract_returned', 'comment_response']),
  instructionNote: z.string().trim().min(1).max(2000),
  requestorUserId: z.number().int().positive(),
  initialStage: z.enum(['not_started', 'in_progress', 'completed']).default('not_started'),
  sourceContractId: z.number().int().positive().nullish(),
});

export async function addToMyQueueHandler(
  rawParams: Record<string, unknown>,
  ctx: ChatHandlerContext,
): Promise<ChatProposalReceipt> {
  if (!ctx.userPermissions.includes('work.read.assigned')) {
    throw new ForbiddenError('Missing permission work.read.assigned');
  }
  const params = paramsSchema.parse(rawParams);

  const data = {
    requestType: params.requestType,
    instructionNote: params.instructionNote,
    requestorUserId: params.requestorUserId,
    initialStage: params.initialStage,
    sourceContractId: params.sourceContractId ?? null,
  };

  const result = (await db.callFunction<Record<string, unknown> | null>(
    'fn_work_order_create_manual',
    [JSON.stringify(data), ctx.userId],
    { actorId: ctx.userId, tenantId: ctx.tenantId },
  )) ?? {};

  const workOrderId = Number(result.workOrderId ?? result.id ?? 0);

  return {
    message: `Added work order #${workOrderId} to your queue.`,
    link: '/app/work',
    params: {
      workOrderId,
      requestType: params.requestType,
    },
  };
}
