// Word the fork banner like GitHub with live counts from /-/trueog-divergence (TrueOG's counting service).
(() => {
	const box = document.querySelector(".trueog-upstream[data-fork]");
	if (!box) return;
	const text = box.querySelector("[data-trueog-upstream-text]");
	const upstream = box.querySelector("[data-trueog-upstream-link]");
	const aheadLink = box.querySelector("[data-trueog-ahead]");
	const behindLink = box.querySelector("[data-trueog-behind]");
	if (!text || !upstream || !aheadLink || !behindLink) return;
	const root = (window.config && window.config.appSubUrl) || "";
	const query = new URLSearchParams({
		fork: box.dataset.fork,
		branch: box.dataset.branch,
		base: box.dataset.base,
		base_branch: box.dataset.baseBranch,
	});
	fetch(`${root}/-/trueog-divergence?${query}`, {credentials: "same-origin"})
		.then((response) => (response.ok ? response.json() : null))
		.then((data) => {
			if (!data || data.unrelated || !Number.isInteger(data.ahead) || !Number.isInteger(data.behind)) return;
			const commits = (n) => `${n.toLocaleString("en-US")} commit${n === 1 ? "" : "s"}`;
			const parts = [document.createTextNode("This branch is ")];
			if (data.ahead === 0 && data.behind === 0) {
				parts.push(document.createTextNode("up to date with "));
			} else {
				if (data.ahead > 0) {
					aheadLink.textContent = `${commits(data.ahead)} ahead of`;
					parts.push(aheadLink);
				}
				if (data.ahead > 0 && data.behind > 0) parts.push(document.createTextNode(", "));
				if (data.behind > 0) {
					behindLink.textContent = `${commits(data.behind)} behind`;
					parts.push(behindLink);
				}
				parts.push(document.createTextNode(" "));
			}
			parts.push(upstream, document.createTextNode("."));
			text.replaceChildren(...parts);
		})
		.catch(() => {});
})();
