// Loaded only inside an interactive omp process launched from YaaTerm.
import {writeSync} from "node:fs";
import type {ExtensionAPI} from "@oh-my-pi/pi-coding-agent";

export default function (pi: ExtensionAPI) {
    if (!process.stdout.isTTY) return;
    const fence = /^[ \t]*(\x60{3,}|~{3,})[^\n]*\n[\s\S]*?(?:^[ \t]*\1[ \t]*$|(?![\s\S]))/gm;
    const heading = /^[ \t]*(?:#{1,6}[ \t]+)?(?:\*\*)?(?:任务总结|总结|摘要|summary|tl;dr)(?:\*\*)?[ \t]*(?:[:：]|$)/im;
    let reply = "";
    pi.on("agent_start", () => { reply = ""; });
    pi.on("turn_end", ({message, toolResults}) => {
        reply = "";
        if (message.role !== "assistant" || toolResults.length || message.stopReason === "toolUse") return;
        for (const part of message.content) {
            if (part.type !== "text" || !part.text) continue;
            const text = part.text.replace(fence, "");
            const section = heading.exec(text);
            if (section) {
                reply = text.slice(section.index, section.index + 360);
                break;
            }
            if (reply.length >= 360) continue;
            if (reply) reply += "\n";
            reply += text.slice(0, 360 - reply.length);
        }
    });
    pi.on("agent_end", ({willContinue}) => {
        if (!willContinue) {
            const text = Buffer.from(reply.replace(/[\uD800-\uDBFF]$/, "")).toString("base64");
            writeSync(1, `\x1b]777;yaaterm-turn;omp;${text}\x07`);
        }
        reply = "";
    });
}
