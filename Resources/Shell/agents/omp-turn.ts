// Loaded only inside an interactive omp process launched from YaaTerm.
import {writeSync} from "node:fs";
import type {ExtensionAPI} from "@oh-my-pi/pi-coding-agent";

export default function (pi: ExtensionAPI) {
    pi.on("agent_end", () => {
        if (process.stdout.isTTY) writeSync(1, "\x1b]777;yaaterm-turn;omp\x07");
    });
}
