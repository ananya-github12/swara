import anydocWasmUrl from '@firecrawl/anydoc-wasm/anydoc_wasm_bg.wasm?url';

export type DocumentConversionResult =
  | { ok: true; markdown: string; format: string }
  | {
      ok: false;
      reason: 'unsupported_format' | 'empty_or_scanned' | 'conversion_failed';
      message: string;
    };

export const ANYDOC_EXTENSIONS = new Set([
  'docx',
  'doc',
  'pptx',
  'ppt',
  'xlsx',
  'xls',
  'odt',
  'ods',
  'odp',
  'rtf',
  'epub',
  'csv',
  'pdf',
]);

type AnydocModule = typeof import('@firecrawl/anydoc-wasm');

let anydocPromise: Promise<AnydocModule> | undefined;

function loadAnydoc(): Promise<AnydocModule> {
  if (!anydocPromise) {
    anydocPromise = import('@firecrawl/anydoc-wasm')
      .then(async (anydoc) => {
        await anydoc.default({ module_or_path: anydocWasmUrl });
        return anydoc;
      })
      .catch((error) => {
        // A transient chunk/WASM load error must not poison every later upload.
        anydocPromise = undefined;
        throw error;
      });
  }
  return anydocPromise;
}

export function extensionOf(fileName: string): string {
  const dotIndex = fileName.lastIndexOf('.');
  return dotIndex === -1 ? '' : fileName.slice(dotIndex + 1).toLowerCase();
}

export async function convertDocument(file: File): Promise<DocumentConversionResult> {
  const extension = extensionOf(file.name);

  if (!ANYDOC_EXTENSIONS.has(extension)) {
    return {
      ok: false,
      reason: 'unsupported_format',
      message:
        "This file type isn't supported. Try Word, PowerPoint, Excel, OpenDocument, RTF, EPUB, CSV, PDF, text, or an image.",
    };
  }

  try {
    const bytes = new Uint8Array(await file.arrayBuffer());
    const anydoc = await loadAnydoc();
    const markdown = extension === 'csv'
      ? anydoc.toMarkdownBytes(bytes, 'csv')
      : anydoc.toMarkdownBytes(bytes);

    if (!markdown.trim()) {
      return {
        ok: false,
        reason: 'empty_or_scanned',
        message: "We couldn't find readable text in this document.",
      };
    }

    return {
      ok: true,
      markdown,
      format: anydoc.formatFromBytes(bytes) ?? extension,
    };
  } catch (error) {
    const code = (error as { code?: unknown } | null)?.code;
    if (code === 'unsupported') {
      return {
        ok: false,
        reason: 'empty_or_scanned',
        message: "We couldn't find readable text in this document.",
      };
    }
    if (code === 'encrypted') {
      return {
        ok: false,
        reason: 'conversion_failed',
        message: 'This document is password-protected. Remove the password and try again.',
      };
    }
    return {
      ok: false,
      reason: 'conversion_failed',
      message: "We couldn't read this document. It may be damaged or in an unexpected format.",
    };
  }
}
