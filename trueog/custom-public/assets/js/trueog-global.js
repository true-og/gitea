// Clarify which staff approval satisfies TrueOG's branch protection. Gitea's locale string only
// says "users or teams on the allowlist" and does not receive the allowed team names as arguments.
// Keep this narrowly scoped to that exact merge-box sentence and preserve the live approval count.
(() => {
	const genericApproval = /(\d+) of (\d+) approvals granted from users or teams on the allowlist\./;
	const path = window.location.pathname.toLowerCase().split("/").filter(Boolean);
	if (path[0] !== "trueog") return;
	const adminOnly = path[0] === "trueog" && path[1] === "true-og";
	const requirement = adminOnly
		? "Required approval team: Admins."
		: "Eligible approval teams: Admins or Developers.";

	function clarifyApprovalText(root) {
		const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
		for (let node = walker.nextNode(); node; node = walker.nextNode()) {
			if (genericApproval.test(node.nodeValue)) {
				node.nodeValue = node.nodeValue.replace(
					genericApproval,
					`$1 of $2 approvals granted. ${requirement}`,
				);
			}
		}
	}

	function start() {
		clarifyApprovalText(document.body);
		new MutationObserver((mutations) => {
			for (const mutation of mutations) {
				for (const node of mutation.addedNodes) {
					if (node.nodeType === Node.ELEMENT_NODE) clarifyApprovalText(node);
				}
			}
		}).observe(document.body, {childList: true, subtree: true});
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", start, {once: true});
	} else {
		start();
	}
})();
