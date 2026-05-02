/**
 * Mailer abstraction (decisions.md G4).
 *
 * Backed by Nodemailer + SMTP (Mailpit in dev, TBD-SMTP in prod). Supports
 * EN/AR template rendering — the implementation reads bilingual templates
 * from `templates/` (added in feature modules).
 *
 * Singleton — `getMailer()` returns the same instance for the process.
 */
import { NodemailerMailer } from './nodemailer.mailer';

export interface MailBody {
  text: string;
  html?: string;
}

export interface MailTemplateVars {
  [key: string]: string | number | boolean | null | undefined;
}

export interface Mailer {
  send(to: string, subject: string, body: MailBody): Promise<void>;
  /**
   * Render a named bilingual template with the supplied vars and send.
   * Locale defaults to 'en'; 'ar' produces an Arabic body when the AR
   * template file exists. Templates live in `templates/<name>.<locale>.html`
   * (and optional `.txt` companion). Feature modules add templates as needed.
   */
  sendTemplate(
    template: string,
    to: string,
    vars: MailTemplateVars,
    opts?: { locale?: 'en' | 'ar'; subjectOverride?: string },
  ): Promise<void>;
}

let _instance: Mailer | null = null;

export const getMailer = (): Mailer => {
  if (_instance) return _instance;
  _instance = new NodemailerMailer();
  return _instance;
};

export const _resetMailer = (): void => {
  _instance = null;
};
