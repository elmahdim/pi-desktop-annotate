export interface Evidence { id: number; file: string; width: number; height: number; capturedAt: string }
export interface AnnotationBundle { version: 2; notes: { id: number; evidenceId: number; kind: string; text: string; region: { x: number; y: number; width: number; height: number } }[]; evidence: Evidence[] }
export function validateBundle(value: unknown): AnnotationBundle;
export function describeBundle(value: AnnotationBundle): string;
export function presentationText(value: AnnotationBundle): string[];
export function loadFeedbackIfPresent(directory: string): Promise<Awaited<ReturnType<typeof loadFeedback>> | undefined>;
export function loadFeedback(directory: string): Promise<{ content: Awaited<ReturnType<typeof loadBundle>>; presentation: string[] }>;
export function loadBundle(directory: string): Promise<({ type: 'text'; text: string } | { type: 'image'; mimeType: string; data: string })[]>;
