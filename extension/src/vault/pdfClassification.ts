import type { PageOcrReasons, PdfType } from '@firecrawl/pdf-inspector-wasm';

export interface PdfClassificationResult {
  pdfType: PdfType;
  pageCount: number;
  pagesNeedingOcr: number[];
  ocrReasonsByPage: PageOcrReasons[];
  confidence: number;
  hasEncodingIssues: boolean;
  processingTimeMs: number;
}

export function shouldUseOcr(classification: PdfClassificationResult): boolean {
  return classification.pdfType === 'Scanned' ||
    classification.pdfType === 'ImageBased' ||
    classification.pdfType === 'Mixed' && classification.pagesNeedingOcr.length > 0 ||
    classification.hasEncodingIssues;
}

export async function classifyPdf(file: File): Promise<PdfClassificationResult> {
  const worker = new Worker(
    new URL('./pdfClassifier.worker.ts', import.meta.url),
    { type: 'module' },
  );
  const id = crypto.randomUUID();
  const buffer = await file.arrayBuffer();

  return new Promise<PdfClassificationResult>((resolve, reject) => {
    const timeout = window.setTimeout(() => {
      worker.terminate();
      reject(new Error('PDF classification timed out'));
    }, 20_000);

    worker.onmessage = (event: MessageEvent<{
      id: string;
      result?: PdfClassificationResult;
      error?: string;
    }>) => {
      if (event.data.id !== id) return;
      window.clearTimeout(timeout);
      worker.terminate();
      if (event.data.result) resolve(event.data.result);
      else reject(new Error(event.data.error || 'PDF classification failed'));
    };
    worker.onerror = () => {
      window.clearTimeout(timeout);
      worker.terminate();
      reject(new Error('PDF classification failed'));
    };
    worker.postMessage({ id, buffer }, [buffer]);
  });
}
