import { CheckCircle2, FileText, ScanLine, UploadCloud, X } from 'lucide-react';

import { DOCUMENT_ACCEPT } from './documentPreparation';

type ScanStage = 'idle' | 'local' | 'ocr' | 'uploading' | 'ready';

type Props = {
  fileName: string | null;
  stage: ScanStage;
  text: string;
  fullText: string;
  sourceValue: string;
  batchProgress?: { current: number; total: number } | null;
  locked?: boolean;
  onFilesSelected: (files: File[]) => void;
  onReset: () => void;
  onTextChange: (value: string) => void;
  onSourceChange: (value: string) => void;
};

function extensionLabel(name: string): string {
  const index = name.lastIndexOf('.');
  return index === -1 ? 'DOC' : name.slice(index + 1).slice(0, 4).toUpperCase();
}

export function DocumentScanUpload({
  fileName,
  stage,
  text,
  fullText,
  sourceValue,
  batchProgress = null,
  locked = false,
  onFilesSelected,
  onReset,
  onTextChange,
  onSourceChange,
}: Props) {
  const working = stage === 'local' || stage === 'uploading';
  const needsOcr = stage === 'ocr';
  const ready = stage === 'ready';

  const onChange = (event: React.ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(event.target.files ?? []);
    if (files.length) onFilesSelected(files);
    event.target.value = '';
  };

  if (!fileName) {
    return (
      <div className="scanner-empty-grid">
        <input
          id="vault-scan-file-input"
          className="hidden-file-input"
          type="file"
          accept={DOCUMENT_ACCEPT}
          multiple
          onChange={onChange}
        />
        <label className="scanner-drop-zone" htmlFor="vault-scan-file-input">
          <span className="scanner-upload-icon"><UploadCloud size={24} /></span>
          <strong>Click to upload documents</strong>
          <span>
            Word, PowerPoint, Excel, OpenDocument, RTF, EPUB, CSV, PDF, images,
            text and Markdown. Readable files stay on this device.
          </span>
        </label>
        <div className="scanner-paste-column">
          <label htmlFor="vault-source">Name</label>
          <input
            id="vault-source"
            value={sourceValue}
            onChange={(event) => onSourceChange(event.target.value)}
            placeholder="e.g. profile-notes.md"
          />
          <label htmlFor="vault-text">Content</label>
          <textarea
            id="vault-text"
            value={text}
            onChange={(event) => onTextChange(event.target.value)}
            placeholder="Or paste profile, résumé, policy, or reference text here…"
          />
        </div>
      </div>
    );
  }

  return (
    <div className="scanner-workspace">
      <section className="scanner-preview-card">
        <header className="scanner-preview-header">
          <div className="scanner-file-title">
            <span className="scanner-file-type">{extensionLabel(fileName)}</span>
            <span title={fileName}>{fileName}</span>
          </div>
          <div className="scanner-preview-actions">
            <span className={`scanner-status scanner-status--${stage}`}>
              {stage === 'ocr' ? 'OCR required' : stage === 'uploading' ? 'Saving' : working ? 'Parsing locally' : 'Ready'}
            </span>
            {batchProgress && <span className="scanner-progress">{batchProgress.current} / {batchProgress.total}</span>}
            <button type="button" onClick={onReset} aria-label="Choose different documents" disabled={locked}>
              <X size={15} />
            </button>
          </div>
        </header>
        <div className="scanner-preview-body">
          {(working || needsOcr) && <div className="scanner-sweep" />}
          {needsOcr ? (
            <div className="scanner-ocr-message">
              <ScanLine size={30} />
              <strong>This document needs OCR</strong>
              <span>Swara will process it in the background after you save it.</span>
            </div>
          ) : (
            <pre>{fullText || text || 'Reading document…'}</pre>
          )}
        </div>
      </section>

      <section className="scanner-output-column">
        <label htmlFor="vault-source">Name</label>
        <input
          id="vault-source"
          value={sourceValue}
          onChange={(event) => onSourceChange(event.target.value)}
          disabled={locked}
        />

        <div className="scanner-pipeline">
          <div><CheckCircle2 size={16} /><span>Reading file</span><small>instant</small></div>
          <div>
            {ready || needsOcr ? <CheckCircle2 size={16} /> : <span className="pipeline-pulse" />}
            <span>{needsOcr ? 'Classified for OCR' : 'Extracting content'}</span>
            <small>{needsOcr ? 'fallback' : ready ? `${text.length.toLocaleString()} chars` : 'local'}</small>
          </div>
          <div>
            {stage === 'uploading' ? <span className="pipeline-pulse" /> : <FileText size={16} />}
            <span>Saving to Vault</span>
            <small>{stage === 'uploading' ? '…' : 'waiting'}</small>
          </div>
        </div>

        <div className="scanner-output-field">
          <div>
            <label htmlFor="vault-text">{ready ? 'Extracted content — edit if needed' : 'Extracted content'}</label>
            {ready && <small>{text.trim() ? text.trim().split(/\s+/).length : 0} words</small>}
          </div>
          <textarea
            id="vault-text"
            value={text}
            readOnly={!ready || locked}
            onChange={(event) => onTextChange(event.target.value)}
            placeholder={needsOcr ? 'OCR output will appear in the document after processing.' : 'Waiting for local parser…'}
          />
        </div>
      </section>
    </div>
  );
}

export type { ScanStage };
