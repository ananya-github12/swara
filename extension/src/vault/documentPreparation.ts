import { ANYDOC_EXTENSIONS, convertDocument, extensionOf } from './anydocConvert';
import { classifyPdf, shouldUseOcr } from './pdfClassification';

export const MAX_DOCUMENT_BYTES = 20 * 1024 * 1024;
export const MAX_BATCH_FILES = 20;
export const MAX_BATCH_BYTES = 100 * 1024 * 1024;

export const DOCUMENT_ACCEPT = [
  '.txt', '.md', '.docx', '.doc', '.pptx', '.ppt', '.xlsx', '.xls',
  '.odt', '.ods', '.odp', '.rtf', '.epub', '.csv', '.pdf',
  '.png', '.jpg', '.jpeg', '.zip',
].join(',');

const DIRECT_TEXT_EXTENSIONS = new Set(['txt', 'md']);
const OCR_ONLY_EXTENSIONS = new Set(['png', 'jpg', 'jpeg', 'zip']);
const ALL_EXTENSIONS = new Set([
  ...DIRECT_TEXT_EXTENSIONS,
  ...OCR_ONLY_EXTENSIONS,
  ...ANYDOC_EXTENSIONS,
]);

export type PreparedDocument =
  | { method: 'local'; markdown: string; format: string }
  | { method: 'ocr'; markdown: ''; format: string };

export function fileValidationError(file: File): string | null {
  const extension = extensionOf(file.name);
  if (!ALL_EXTENSIONS.has(extension)) {
    return `${file.name}: This file type is not supported.`;
  }
  if (file.size > MAX_DOCUMENT_BYTES) {
    return `${file.name}: Documents must be 20 MB or smaller.`;
  }
  return null;
}

export async function prepareDocument(file: File): Promise<PreparedDocument> {
  const extension = extensionOf(file.name);
  const validationError = fileValidationError(file);
  if (validationError) throw new Error(validationError);

  if (DIRECT_TEXT_EXTENSIONS.has(extension)) {
    const markdown = await file.text();
    if (!markdown.trim()) throw new Error('This document contains no readable text.');
    return { method: 'local', markdown, format: extension };
  }

  if (OCR_ONLY_EXTENSIONS.has(extension)) {
    return { method: 'ocr', markdown: '', format: extension };
  }

  let classification = null;
  if (extension === 'pdf') {
    try {
      classification = await classifyPdf(file);
    } catch {
      // Classification is a cost optimization. AnyDoc is still a safe local
      // attempt, and an empty result below will route the PDF to OCR.
    }
    if (classification && shouldUseOcr(classification)) {
      return { method: 'ocr', markdown: '', format: extension };
    }
  }

  const result = await convertDocument(file);
  if (result.ok) {
    return { method: 'local', markdown: result.markdown, format: result.format };
  }
  if (extension === 'pdf' && result.reason === 'empty_or_scanned') {
    return { method: 'ocr', markdown: '', format: extension };
  }
  throw new Error(result.message);
}
