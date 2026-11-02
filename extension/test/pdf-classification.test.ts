import assert from 'node:assert/strict';

import {
  shouldUseOcr,
  type PdfClassificationResult,
} from '../src/vault/pdfClassification';

function classification(
  overrides: Partial<PdfClassificationResult> = {},
): PdfClassificationResult {
  return {
    pdfType: 'TextBased',
    pageCount: 2,
    pagesNeedingOcr: [],
    ocrReasonsByPage: [],
    confidence: 0.99,
    hasEncodingIssues: false,
    processingTimeMs: 12,
    ...overrides,
  };
}

assert.equal(shouldUseOcr(classification()), false);
assert.equal(shouldUseOcr(classification({ confidence: 0.2 })), false);
assert.equal(shouldUseOcr(classification({ pdfType: 'Scanned' })), true);
assert.equal(shouldUseOcr(classification({ pdfType: 'ImageBased' })), true);
assert.equal(shouldUseOcr(classification({ pdfType: 'Mixed' })), false);
assert.equal(
  shouldUseOcr(classification({ pdfType: 'Mixed', pagesNeedingOcr: [2] })),
  true,
);
assert.equal(shouldUseOcr(classification({ hasEncodingIssues: true })), true);

console.log('All PDF classification checks passed.');
