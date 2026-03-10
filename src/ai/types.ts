export type AiProviderId =
	| "github-copilot"
	| "openai"
	| "google"
	| "anthropic"
	| "doubao"
	| "kimi"
	| "qwen";

export type AiAuthType = "api-key" | "oauth-device" | "access-token";

export type AiToolKind =
	| "workspace-read"
	| "workspace-edit"
	| "search"
	| "terminal"
	| "mcp"
	| "diagnostics";

export type ApprovalMode = "manual" | "auto";

export type ApprovalScope = "once" | "session" | "workspace";

export type ApprovalTarget =
	| "file-read"
	| "file-edit"
	| "terminal"
	| "mcp";

export interface AiModelDescriptor {
	id: string;
	displayName: string;
	contextWindow?: number;
	supportsStreaming: boolean;
	supportsTools: boolean;
	supportsMcp: boolean;
	inputPriceHint?: string;
	outputPriceHint?: string;
}

export interface AiProviderDescriptor {
	id: AiProviderId;
	displayName: string;
	authType: AiAuthType;
	supportsStreaming: boolean;
	supportsTools: boolean;
	supportsMcp: boolean;
	models: AiModelDescriptor[];
}

export interface AiMessage {
	role: "system" | "user" | "assistant" | "tool";
	content: string;
	name?: string;
	toolCallId?: string;
	createdAt?: number;
}

export interface AiWorkspaceContext {
	workspaceRoot: string;
	activeFile?: string;
	selectedText?: string;
	recentFiles?: string[];
	openFiles?: string[];
}

export interface AiToolCallRequest {
	id: string;
	kind: AiToolKind;
	name: string;
	arguments: Record<string, unknown>;
	riskLevel: "low" | "medium" | "high";
	providerId: AiProviderId;
	sessionId: string;
}

export interface AiToolCallResult {
	id: string;
	ok: boolean;
	content: string;
	structuredContent?: unknown;
	errorCode?:
		| "permission-denied"
		| "tool-failed"
		| "invalid-arguments"
		| "cancelled";
	}

export interface ApprovalRule {
	target: ApprovalTarget;
	mode: ApprovalMode;
	scope: ApprovalScope;
	workspaceRoots?: string[];
	providerIds?: AiProviderId[];
	mcpServerIds?: string[];
	commandAllowList?: string[];
	pathAllowList?: string[];
}

export interface ApprovalDecision {
	requestId: string;
	approved: boolean;
	scope: ApprovalScope;
	reason?: string;
	decidedAt: number;
	decidedBy: "user" | "policy";
}

export interface McpToolDescriptor {
	name: string;
	description: string;
	inputSchema?: unknown;
	approvalTarget: "mcp";
}

export interface McpServerDescriptor {
	id: string;
	pluginId: string;
	displayName: string;
	transport: "stdio" | "websocket" | "http";
	endpoint?: string;
	command?: string;
	args?: string[];
	env?: Record<string, string>;
	disabledByDefault: boolean;
	tools: McpToolDescriptor[];
}

export interface AiSessionDescriptor {
	id: string;
	providerId: AiProviderId;
	modelId: string;
	context: AiWorkspaceContext;
	messages: AiMessage[];
	approvalRules: ApprovalRule[];
	attachedMcpServerIds: string[];
	createdAt: number;
	updatedAt: number;
}

export interface ProviderChatRequest {
	session: AiSessionDescriptor;
	messages: AiMessage[];
	availableTools: AiToolDefinition[];
	abortSignal?: AbortSignal;
	onTextDelta?: (text: string) => void;
	onToolCall?: (request: AiToolCallRequest) => Promise<AiToolCallResult>;
}

export interface ProviderChatResponse {
	message: AiMessage;
	finishReason: "stop" | "tool-calls" | "length" | "error";
	usage?: {
		inputTokens?: number;
		outputTokens?: number;
	};
}

export interface AiProviderAdapter {
	readonly descriptor: AiProviderDescriptor;
	loadModels(): Promise<AiModelDescriptor[]>;
	ensureAuthenticated(): Promise<void>;
	sendMessage(request: ProviderChatRequest): Promise<ProviderChatResponse>;
	cancel?(sessionId: string): Promise<void>;
	logout?(): Promise<void>;
}

export interface AiToolDefinition {
	kind: AiToolKind;
	name: string;
	description: string;
	requiresApproval: boolean;
	inputSchema?: unknown;
	execute(request: AiToolCallRequest): Promise<AiToolCallResult>;
}

export interface AiRuntime {
	listProviders(): Promise<AiProviderDescriptor[]>;
	createSession(input: {
		providerId: AiProviderId;
		modelId: string;
		context: AiWorkspaceContext;
	}): Promise<AiSessionDescriptor>;
	getSession(sessionId: string): Promise<AiSessionDescriptor | null>;
	saveSession(session: AiSessionDescriptor): Promise<void>;
	sendMessage(sessionId: string, message: AiMessage): Promise<ProviderChatResponse>;
	cancelRun(sessionId: string): Promise<void>;
	listTools(sessionId: string): Promise<AiToolDefinition[]>;
	listMcpServers(): Promise<McpServerDescriptor[]>;
	attachMcpServer(sessionId: string, serverId: string): Promise<void>;
	detachMcpServer(sessionId: string, serverId: string): Promise<void>;
	requestApproval(request: AiToolCallRequest): Promise<ApprovalDecision>;
}