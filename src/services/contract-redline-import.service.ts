/**
 * contract-redline-import.service.ts  (Scenario 2)
 *
 * Counterparty redline upload + diff. A drafter uploads the counterparty's
 * returned contract file; we extract its text (reusing extractTextFromBuffer
 * from tpa-analyzer), split our current contract body and theirs into "## "
 * clause sections, compute a clause-section diff (added / removed / modified),
 * persist it (mig 710), let the drafter accept/reject, and assemble accepted
 * changes into a new contract_version (fn_contract_version_create).
 *
 * Heading alignment: our body is markdown ("## Heading"). A returned .docx/.pdf
 * extracts to PLAIN text (markdown markers stripped), so when their text has no
 * "## " headings we align it to OUR clause structure by locating each of our
 * headings inside their text and slicing the body between them. When their text
 * DOES preserve "## " headings (e.g. a returned .md/.txt) we parse it directly,
 * which also lets us detect brand-new (added) clauses.
 */
import { db } from '../database/client';
import { extractTextFromBuffer } from './tpa-analyzer.service';
import { ValidationError } from '../utils/errors.util';

interface ClauseSegment {
  id: string;
  heading: string;
  body: string;
}

export interface RedlineChange {
  clauseId: string;
  clauseHeading: string;
  changeType: 'added' | 'removed' | 'modified';
  ourText: string | null;
  theirText: string | null;
}

// ── Clause parsing (ported from FE ContractDocumentTab.parseClauses) ─────────

function slugify(s: string): string {
  return (
    s
      .toLowerCase()
      .normalize('NFKD')
      .replace(/[̀-ͯ]/g, '')
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 60) || 'section'
  );
}

function parseClauses(body: string | null): ClauseSegment[] {
  if (!body) return [];
  const lines = body.split(/\r?\n/);
  const segments: ClauseSegment[] = [];
  let currentHeading = '';
  let currentBody: string[] = [];
  const seen = new Map<string, number>();

  const push = (): void => {
    if (currentHeading === '' && currentBody.every((l) => l.trim() === '')) return;
    const baseSlug = currentHeading ? slugify(currentHeading) : 'preamble';
    const count = seen.get(baseSlug) ?? 0;
    seen.set(baseSlug, count + 1);
    const id = count === 0 ? baseSlug : `${baseSlug}-${count + 1}`;
    segments.push({ id, heading: currentHeading, body: currentBody.join('\n').trim() });
  };

  for (const line of lines) {
    const m = /^##\s+(.+)$/.exec(line.trim());
    if (m) {
      push();
      currentHeading = m[1] ?? '';
      currentBody = [];
    } else {
      currentBody.push(line);
    }
  }
  push();
  return segments;
}

const normalize = (t: string | null): string => (t ?? '').replace(/\s+/g, ' ').trim();
const headingKey = (h: string): string => h.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

/**
 * Align a plain-text counterparty doc to OUR clause structure by locating each
 * of our headings inside their text, then slicing the body between anchors.
 */
function alignByOurHeadings(theirText: string, ourSections: ClauseSegment[]): ClauseSegment[] {
  const lines = theirText.split(/\r?\n/);
  const lineKeys = lines.map((l) => headingKey(l));
  const anchors: Array<{ idx: number; id: string; heading: string }> = [];
  const usedLines = new Set<number>();

  for (const sec of ourSections) {
    if (!sec.heading) continue;
    const target = headingKey(sec.heading);
    if (target.length < 4) continue;
    // Match a line that equals the heading or contains it (ignoring leading
    // numbering like "18." that mammoth keeps from the Word doc).
    const idx = lineKeys.findIndex(
      (k, i) => !usedLines.has(i) && k.length > 0 && (k === target || k.endsWith(target) || (target.length > 6 && k.includes(target))),
    );
    if (idx >= 0) {
      usedLines.add(idx);
      anchors.push({ idx, id: sec.id, heading: sec.heading });
    }
  }
  anchors.sort((a, b) => a.idx - b.idx);

  const result: ClauseSegment[] = [];
  for (let i = 0; i < anchors.length; i += 1) {
    const start = anchors[i]!.idx + 1;
    const end = i + 1 < anchors.length ? anchors[i + 1]!.idx : lines.length;
    result.push({
      id: anchors[i]!.id,
      heading: anchors[i]!.heading,
      body: lines.slice(start, end).join('\n').trim(),
    });
  }
  return result;
}

function parseTheirs(theirText: string, ourSections: ClauseSegment[]): ClauseSegment[] {
  const md = parseClauses(theirText);
  // If their doc preserved "## " headings, use it directly (also detects adds).
  if (md.filter((s) => s.heading).length >= 2) return md;
  return alignByOurHeadings(theirText, ourSections);
}

/** Compute the clause-section diff of their doc against our current body. */
export function diffClauses(ourBody: string | null, theirText: string): RedlineChange[] {
  const our = parseClauses(ourBody);
  const their = parseTheirs(theirText, our);
  const ourById = new Map(our.map((s) => [s.id, s]));
  const theirById = new Map(their.map((s) => [s.id, s]));
  const changes: RedlineChange[] = [];

  for (const ts of their) {
    if (!ts.heading) continue; // skip preamble noise from extracted text
    const os = ourById.get(ts.id);
    if (!os) {
      changes.push({
        clauseId: ts.id,
        clauseHeading: ts.heading,
        changeType: 'added',
        ourText: null,
        theirText: ts.body,
      });
    } else if (normalize(os.body) !== normalize(ts.body) && ts.body.trim().length > 0) {
      changes.push({
        clauseId: ts.id,
        clauseHeading: ts.heading || os.heading,
        changeType: 'modified',
        ourText: os.body,
        theirText: ts.body,
      });
    }
  }
  for (const os of our) {
    if (!os.heading) continue;
    if (!theirById.has(os.id)) {
      changes.push({
        clauseId: os.id,
        clauseHeading: os.heading,
        changeType: 'removed',
        ourText: os.body,
        theirText: null,
      });
    }
  }
  return changes;
}

/** Assemble a new body from our current body + the accepted changes. */
export function buildNewBody(
  ourBody: string | null,
  changes: Array<{ clauseId: string; clauseHeading: string; changeType: string; theirText: string | null; decision: string }>,
): string {
  const our = parseClauses(ourBody);
  const modified = new Map<string, string>();
  const removed = new Set<string>();
  const added: Array<{ heading: string; body: string }> = [];

  for (const ch of changes) {
    if (ch.decision !== 'accepted') continue;
    if (ch.changeType === 'modified') modified.set(ch.clauseId, ch.theirText ?? '');
    else if (ch.changeType === 'removed') removed.add(ch.clauseId);
    else if (ch.changeType === 'added') added.push({ heading: ch.clauseHeading, body: ch.theirText ?? '' });
  }

  const out: string[] = [];
  for (const s of our) {
    if (removed.has(s.id)) continue;
    const body = modified.has(s.id) ? modified.get(s.id)! : s.body;
    out.push(s.heading ? `## ${s.heading}\n\n${body}`.trim() : body.trim());
  }
  for (const a of added) {
    out.push(`## ${a.heading}\n\n${a.body}`.trim());
  }
  return out.filter((x) => x.trim().length > 0).join('\n\n');
}

// ── Orchestration (DB passthroughs + flow) ───────────────────────────────────

interface ContractRow {
  id: number;
  bodyEn: string | null;
  currentVersion: number;
}

const getContract = (actorId: number, role: string, contractId: number): Promise<ContractRow | null> =>
  db.callFunction<ContractRow | null>('fn_contract_get_by_id', [contractId, actorId, role], {
    actorId,
  });

export const importRedline = async (args: {
  actorId: number;
  role: string;
  contractId: number;
  filename: string;
  mime: string;
  buffer: Buffer;
}): Promise<unknown> => {
  const contract = await getContract(args.actorId, args.role, args.contractId);
  if (!contract) throw new ValidationError('Contract not found or not accessible');

  const extracted = await extractTextFromBuffer(args.buffer, args.mime);
  if (!extracted.text || extracted.text.trim().length === 0) {
    throw new ValidationError('Could not extract any text from the uploaded file.');
  }

  const changes = diffClauses(contract.bodyEn, extracted.text);

  return db.callFunction(
    'fn_contract_redline_import_create',
    [
      args.actorId,
      args.contractId,
      args.filename,
      args.mime,
      extracted.engine,
      contract.currentVersion,
      extracted.text,
      changes,
    ],
    { actorId: args.actorId },
  );
};

export const getImport = (actorId: number, importId: number): Promise<unknown> =>
  db.callFunction('fn_contract_redline_import_get', [actorId, importId], { actorId });

export const listImports = (actorId: number, contractId: number): Promise<unknown> =>
  db.callFunction('fn_contract_redline_import_list', [actorId, contractId], { actorId });

export const decideChange = (
  actorId: number,
  changeId: number,
  decision: string,
): Promise<unknown> =>
  db.callFunction('fn_contract_redline_change_decide', [actorId, changeId, decision], { actorId });

interface ImportDetail {
  contractId: number;
  filename: string;
  status: string;
  changes: Array<{
    clauseId: string;
    clauseHeading: string;
    changeType: string;
    theirText: string | null;
    decision: string;
  }>;
}

interface VersionCreated {
  id: number;
  versionNumber: number;
}

export const applyImport = async (args: {
  actorId: number;
  role: string;
  importId: number;
}): Promise<{ versionNumber: number; appliedChanges: number }> => {
  const imp = (await getImport(args.actorId, args.importId)) as ImportDetail;
  if (imp.status === 'applied') {
    throw new ValidationError('This redline import has already been applied.');
  }
  const accepted = imp.changes.filter((c) => c.decision === 'accepted');
  if (accepted.length === 0) {
    throw new ValidationError('Accept at least one change before applying.');
  }

  const contract = await getContract(args.actorId, args.role, imp.contractId);
  if (!contract) throw new ValidationError('Contract not found or not accessible');

  const newBody = buildNewBody(contract.bodyEn, imp.changes);

  const version = (await db.callFunction<VersionCreated>(
    'fn_contract_version_create',
    [
      imp.contractId,
      {
        bodyEn: newBody,
        changeNote: `Incorporated counterparty redline (${accepted.length} change(s)) from ${imp.filename}`.slice(0, 500),
      },
      args.actorId,
    ],
    { actorId: args.actorId },
  ));

  await db.callFunction(
    'fn_contract_redline_import_set_status',
    [args.actorId, args.importId, 'applied', version.versionNumber],
    { actorId: args.actorId },
  );

  return { versionNumber: version.versionNumber, appliedChanges: accepted.length };
};
