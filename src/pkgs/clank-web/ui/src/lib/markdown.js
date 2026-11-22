import { marked } from 'marked';
import DOMPurify from 'dompurify';

// Claude's summaries are Markdown. Rendered, then sanitized.
export function renderMarkdown(text) {
  return DOMPurify.sanitize(marked.parse(text ?? '', { async: false, gfm: true, breaks: false }));
}
