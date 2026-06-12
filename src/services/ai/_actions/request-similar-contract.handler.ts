/**
 * Write-action handler: request_similar_contract.
 *
 * Called from /ai/chat/execute after the user confirms the proposal card.
 * Wraps the exact same fn_ the REST endpoint /work-orders/from-contract calls,
 * so any future change to the underlying flow (e.g. notification fan-out)
 * applies equally to chat and dialog paths.
 */
import { z } from 'zod';
import { db } from '../../../database/client';
import { ForbiddenError } from '../../../utils/errors.util';
import type { ChatHandlerContext, ChatProposalReceipt } from '../../../types/chat-orchestrator.types';

const paramsSchema = z
  .object({
    sourceContractId: z.number().int().positive(),
    assignedDrafterId: z.number().int().positive(),
    counterpartyId: z.number().int().positive().nullish(),
    counterpartyProspectName: z.string().trim().min(1).max(200).nullish(),
    instructionNote: z.string().trim().max(2000).nullish(),
  })
  .refine(
    (v) => (v.counterpartyId != null) !== !!(v.counterpartyProspectName && v.counterpartyProspectName.length > 0),
    {
      message:
        'Exactly one of counterpartyId or counterpartyProspectName must be supplied.',
      path: ['counterpartyId'],
    },
  );

export async function requestSimilarContractHandler(
  rawParams: Record<string, unknown>,
  ctx: ChatHandlerContext,
): Promise<ChatProposalReceipt> {
  if (!ctx.userPermissions.includes('work.create')) {
    throw new ForbiddenError('Missing permission work.create');
  }
  const params = paramsSchema.parse(rawParams);

  const data = {
    counterpartyId: params.counterpartyId ?? null,
    counterpartyProspectName: params.counterpartyProspectName ?? null,
    instructionNote: params.instructionNote ?? null,
    valueAed: null,
    priority: 'normal',
    dueAt: null,
  };

  const result = (await db.callFunction<Record<string, unknown> | null>(
    'fn_work_order_create_draft_request',
    [
      params.sourceContractId,
      params.assignedDrafterId,
      ctx.userId,
      JSON.stringify(data),
    ],
    { actorId: ctx.userId, tenantId: ctx.tenantId },
  )) ?? {};

  const workOrderId = Number(result.workOrderId ?? result.id ?? 0);
  const sourceContractNumber = (result.sourceContractNumber ?? result.contractNumber ?? '') as string;
  const drafter = (result.assignedDrafter ?? {}) as { id?: number; name?: string };
  const drafterName = drafter.name ?? 'the assigned drafter';

  return {
    message: `Work order #${workOrderId} created for ${drafterName} (source ${sourceContractNumber}).`,
    link: '/app/work',
    params: {
      workOrderId,
      drafterName,
      sourceContractNumber,
    },
  };
}
