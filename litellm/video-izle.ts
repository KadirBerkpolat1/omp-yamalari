import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

// Watches local videos with a Gemini model behind Berk's LiteLLM. LiteLLM
// forwards OpenAI `video_url` parts to omniroute, whose cursor-video patch
// (VPS: /root/omniroute/patches/cursor-video-patch.mjs) hands them to Cursor;
// Cursor reads videos only on Gemini models.
const PROVIDER = "litellm";
const DEFAULT_MODEL = "gemini-3.1-pro";
const MAX_VIDEOS = 5;
// Cursor answers a bigger video with 502 "Video exceeds maximum size", which omniroute retries.
const MAX_VIDEO_MB = 15;
// omniroute holds every large request body (base64 adds a third) against one 35 MB ingest budget
// that all in-flight requests share until they finish; 20 MB of video leaves room for the rest.
const MAX_TOTAL_MB = 20;
const MIME_TYPES: Record<string, string> = {
	".mp4": "video/mp4",
	".m4v": "video/x-m4v",
	".mov": "video/quicktime",
	".webm": "video/webm",
	".mkv": "video/x-matroska",
	".avi": "video/x-msvideo",
	".mpeg": "video/mpeg",
	".mpg": "video/mpeg",
	".3gp": "video/3gpp",
	".flv": "video/x-flv",
	".wmv": "video/x-ms-wmv",
};
const SHRINK_HINT =
	"Shrink first, e.g. `ffmpeg -i in.mp4 -vf scale=-2:720 -c:v libx264 -crf 28 -c:a aac -b:a 96k out.mp4`, or cut with -ss/-t.";
const SYSTEM_PROMPT =
	"You watch videos for another agent that cannot see or hear them.\n\n" +
	"Report what the attached videos actually contain: the picture, on-screen text, speech, music and other sound. " +
	"Give a timestamp (mm:ss) for each finding. Answer the request directly, then list what you could not make out. " +
	"Never describe more than the videos show; say so when something is unclear.";

interface VideoFile {
	path: string;
	mimeType: string;
	bytes: number;
}

function megabytes(bytes: number): string {
	return (bytes / 1024 / 1024).toFixed(1);
}

/** The LiteLLM endpoint omp itself uses for the `litellm` provider; LITELLM_* env vars fill what models.yml lacks. */
async function resolveLiteLLM(ctx: ExtensionContext) {
	const registry = ctx.modelRegistry;
	const registryKey = await registry.getApiKeyForProvider(PROVIDER);
	const registryUrl = registry.getProviderBaseUrl(PROVIDER);
	const fromRegistry = registryKey !== undefined && registryUrl !== undefined;
	const baseUrl = fromRegistry ? registryUrl : (process.env.LITELLM_BASE_URL ?? registryUrl);
	const apiKey = fromRegistry ? registryKey : (process.env.LITELLM_API_KEY ?? registryKey);
	const missing = [!baseUrl && "base URL", !apiKey && "API key"].filter(Boolean);
	if (!baseUrl || !apiKey) {
		throw new Error(
			`video_izle cannot reach LiteLLM: missing ${missing.join(" and ")}. Configure the \`${PROVIDER}\` provider ` +
				"(baseUrl, apiKey) in ~/.omp/agent/models.yml, or set LITELLM_BASE_URL and LITELLM_API_KEY.",
		);
	}
	const headers = fromRegistry ? await registry.getProviderHeaders(PROVIDER) : undefined;
	return { url: `${baseUrl.replace(/\/+$/, "")}/chat/completions`, apiKey, headers };
}

async function statVideos(paths: readonly string[], cwd: string): Promise<VideoFile[]> {
	if (paths.length === 0 || paths.length > MAX_VIDEOS) {
		throw new Error(`video_izle takes 1 to ${MAX_VIDEOS} videos, got ${paths.length}`);
	}
	const videos: VideoFile[] = [];
	for (const raw of paths) {
		const file = path.resolve(cwd, raw.startsWith("~/") ? path.join(os.homedir(), raw.slice(2)) : raw);
		const mimeType = MIME_TYPES[path.extname(file).toLowerCase()];
		if (!mimeType) {
			throw new Error(`${raw}: not a supported video type (${Object.keys(MIME_TYPES).join(", ")})`);
		}
		const stat = await fs.stat(file).catch(() => undefined);
		if (!stat?.isFile()) throw new Error(`${raw}: no such file`);
		if (stat.size === 0) throw new Error(`${raw}: file is empty`);
		if (stat.size > MAX_VIDEO_MB * 1024 * 1024) {
			throw new Error(`${raw} is ${megabytes(stat.size)} MB; Cursor accepts at most ${MAX_VIDEO_MB} MB per video. ${SHRINK_HINT}`);
		}
		videos.push({ path: file, mimeType, bytes: stat.size });
	}
	const total = videos.reduce((sum, video) => sum + video.bytes, 0);
	if (total > MAX_TOTAL_MB * 1024 * 1024) {
		throw new Error(`Videos are ${megabytes(total)} MB in total; the limit is ${MAX_TOTAL_MB} MB. ${SHRINK_HINT}`);
	}
	return videos;
}

function answerText(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.map(part => (part && typeof part === "object" && typeof part.text === "string" ? part.text : ""))
		.join("");
}

export default function videoIzle(pi: ExtensionAPI) {
	const z = pi.zod;

	pi.registerTool({
		name: "video_izle",
		label: "Video İzle",
		description:
			"Watch local video files with Gemini through LiteLLM and answer a question about them: the picture, " +
			`on-screen text, speech, music and other sound, with timestamps. 1-${MAX_VIDEOS} files, at most ${MAX_VIDEO_MB} MB each ` +
			`and ${MAX_TOTAL_MB} MB in total ` +
			"(mp4, mov, webm, mkv, avi, mpeg, 3gp, flv, wmv).",
		parameters: z.object({
			paths: z
				.array(z.string())
				.min(1)
				.max(MAX_VIDEOS)
				.describe("Local video files, absolute or relative to the working directory"),
			prompt: z.string().min(1).describe("What to find out about the videos"),
			model: z
				.string()
				.optional()
				.describe(`LiteLLM model that reads video; Gemini only (default ${DEFAULT_MODEL})`),
		}),
		async execute(_toolCallId, params, signal, onUpdate, ctx) {
			const model = params.model?.trim() || DEFAULT_MODEL;
			if (!/gemini/i.test(model)) {
				throw new Error(`video_izle needs a Gemini model; Cursor reads videos only on Gemini (got ${model})`);
			}
			const videos = await statVideos(params.paths, ctx.cwd);
			const endpoint = await resolveLiteLLM(ctx);
			const total = videos.reduce((sum, video) => sum + video.bytes, 0);
			onUpdate?.({
				content: [{ type: "text", text: `Sending ${videos.length} video(s), ${megabytes(total)} MB, to ${model}…` }],
			});

			const parts: unknown[] = [
				{
					type: "text",
					text: `${params.prompt}\n\nAttached videos, in order:\n${videos.map((video, i) => `${i + 1}. ${path.basename(video.path)}`).join("\n")}`,
				},
			];
			for (const video of videos) {
				const data = await fs.readFile(video.path, { signal });
				parts.push({ type: "video_url", video_url: { url: `data:${video.mimeType};base64,${data.toString("base64")}` } });
			}
			const response = await fetch(endpoint.url, {
				method: "POST",
				headers: { ...endpoint.headers, authorization: `Bearer ${endpoint.apiKey}`, "content-type": "application/json" },
				body: JSON.stringify({
					model,
					stream: false,
					messages: [
						{ role: "system", content: SYSTEM_PROMPT },
						{ role: "user", content: parts },
					],
				}),
				signal,
			});
			const raw = await response.text();
			let json: any;
			try {
				json = JSON.parse(raw);
			} catch {}
			if (!response.ok) {
				const message = json?.error?.message ?? raw.slice(0, 500);
				throw new Error(`LiteLLM ${response.status} from ${model}: ${message}`);
			}
			const answer = answerText(json?.choices?.[0]?.message?.content).trim();
			if (!answer) throw new Error(`${model} returned no answer`);
			return {
				content: [{ type: "text", text: answer }],
				details: { model, videos: videos.map(video => ({ path: video.path, bytes: video.bytes })) },
			};
		},
	});
}
