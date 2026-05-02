/**
 * Nodemailer SMTP mailer.
 *
 * Provider-agnostic via env vars (SMTP_HOST/PORT/USER/PASS/FROM_*).
 * In dev, Mailpit catches everything at localhost:1025.
 *
 * Bilingual template support: reads `templates/<name>.<locale>.html` and
 * `templates/<name>.<locale>.txt`. Variable substitution is `{{varName}}`
 * (no expression evaluation — just string-replace). HTML output is HTML-
 * escaped for variables to prevent injection.
 */
import fs from 'node:fs/promises';
import path from 'node:path';
import nodemailer, { type Transporter } from 'nodemailer';
import { env } from '../../utils/env-validation.util';
import { logger } from '../../utils/logger.util';
import { InternalError } from '../../utils/errors.util';
import type { Mailer, MailBody, MailTemplateVars } from './index';

const TEMPLATES_DIR = path.resolve(__dirname, 'templates');

const escapeHtml = (s: string): string =>
  s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');

const renderTemplate = (template: string, vars: MailTemplateVars, isHtml: boolean): string =>
  template.replace(/\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}/g, (_, key: string) => {
    const v = vars[key];
    if (v === undefined || v === null) return '';
    const str = String(v);
    return isHtml ? escapeHtml(str) : str;
  });

export class NodemailerMailer implements Mailer {
  private transporter: Transporter;
  private from: string;

  constructor() {
    const e = env();
    this.transporter = nodemailer.createTransport({
      host: e.SMTP_HOST,
      port: e.SMTP_PORT,
      secure: e.SMTP_PORT === 465,
      auth:
        e.SMTP_USER && e.SMTP_PASS
          ? { user: e.SMTP_USER, pass: e.SMTP_PASS }
          : undefined,
    });
    this.from = `"${e.SMTP_FROM_NAME}" <${e.SMTP_FROM_EMAIL}>`;
  }

  async send(to: string, subject: string, body: MailBody): Promise<void> {
    try {
      await this.transporter.sendMail({
        from: this.from,
        to,
        subject,
        text: body.text,
        ...(body.html ? { html: body.html } : {}),
      });
      logger.info({ action: 'mail.sent', to, subject }, 'Email sent');
    } catch (err) {
      logger.error(
        {
          action: 'mail.send_failed',
          to,
          subject,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'Email send failed',
      );
      throw new InternalError('Email send failed');
    }
  }

  async sendTemplate(
    template: string,
    to: string,
    vars: MailTemplateVars,
    opts: { locale?: 'en' | 'ar'; subjectOverride?: string } = {},
  ): Promise<void> {
    const locale = opts.locale ?? 'en';
    const baseName = template.replace(/[^a-zA-Z0-9_-]/g, '');
    const htmlPath = path.join(TEMPLATES_DIR, `${baseName}.${locale}.html`);
    const textPath = path.join(TEMPLATES_DIR, `${baseName}.${locale}.txt`);

    let htmlSrc: string | null = null;
    let textSrc: string | null = null;

    try {
      htmlSrc = await fs.readFile(htmlPath, 'utf8');
    } catch {
      htmlSrc = null;
    }
    try {
      textSrc = await fs.readFile(textPath, 'utf8');
    } catch {
      textSrc = null;
    }

    if (!htmlSrc && !textSrc) {
      throw new InternalError(
        `Email template "${baseName}" missing for locale "${locale}". Add at least one of: ${baseName}.${locale}.html / ${baseName}.${locale}.txt`,
      );
    }

    const subjectFromVars = typeof vars.subject === 'string' ? vars.subject : undefined;
    const subject =
      opts.subjectOverride ?? subjectFromVars ?? `[${baseName}]`;

    const body: MailBody = {
      text: textSrc ? renderTemplate(textSrc, vars, false) : '',
    };
    if (htmlSrc) {
      body.html = renderTemplate(htmlSrc, vars, true);
    }

    await this.send(to, subject, body);
  }
}
