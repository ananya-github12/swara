import initPdfInspector, { detectPdf } from '@firecrawl/pdf-inspector-wasm';
import pdfInspectorWasmUrl from '@firecrawl/pdf-inspector-wasm/pdf_inspector_wasm_bg.wasm?url';

let initialized: Promise<unknown> | null = null;

function ensureInitialized() {
  initialized ??= initPdfInspector({ module_or_path: pdfInspectorWasmUrl });
  return initialized;
}

self.onmessage = async (event: MessageEvent<{ id: string; buffer: ArrayBuffer }>) => {
  const { id, buffer } = event.data;
  try {
    await ensureInitialized();
    const result = detectPdf(new Uint8Array(buffer));
    self.postMessage({
      id,
      result: {
        pdfType: result.pdfType,
        pageCount: result.pageCount,
        pagesNeedingOcr: result.pagesNeedingOcr,
        ocrReasonsByPage: result.ocrReasonsByPage,
        confidence: result.confidence,
        hasEncodingIssues: result.hasEncodingIssues,
        processingTimeMs: result.processingTimeMs,
      },
    });
  } catch (error) {
    self.postMessage({
      id,
      error: error instanceof Error ? error.message : 'PDF classification failed',
    });
  }
};
