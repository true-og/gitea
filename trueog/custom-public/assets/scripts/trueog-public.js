(() => {
	"use strict";

	// This helper loads synchronously from <head>, before the navbar is parsed, so it can hide the
	// navbar until the session check settles; signed-in visitors then never see the guest links
	// first. Nothing is hidden without JavaScript or if this file fails to load. trueog-js also lets
	// the stylesheet collapse the phone navbar behind its menu toggle, which needs this script.
	const root = document.documentElement;
	root.classList.add("trueog-js", "trueog-auth-pending");
	const revealNavigation = () => root.classList.remove("trueog-auth-pending");
	// Fail open: a slow or stalled session check must not keep the navbar hidden.
	const revealTimer = window.setTimeout(revealNavigation, 2500);

	const domReady = new Promise((resolve) => {
		if (document.readyState === "loading") {
			document.addEventListener("DOMContentLoaded", resolve, { once: true });
		} else {
			resolve();
		}
	});

	const fetchNativePage = async () => {
		let response;
		try {
			response = await fetch("/explore/repos", {
				method: "GET",
				credentials: "same-origin",
				cache: "no-store",
				redirect: "error",
				headers: { Accept: "text/html" },
			});
		} catch {
			return null;
		}
		if (!response.ok) return null;

		try {
			return new DOMParser().parseFromString(await response.text(), "text/html");
		} catch {
			return null;
		}
	};

	// Match the theme Gitea renders for this visitor: a fixed light or dark account theme overrides
	// the OS preference, while Gitea's auto themes follow it like the stylesheet already does.
	const applyTheme = (nativePage) => {
		const theme = nativePage.documentElement.getAttribute("data-theme") || "";
		if (theme.includes("auto")) return;
		if (theme.includes("dark")) root.classList.add("trueog-theme-dark");
		else if (theme.includes("light")) root.classList.add("trueog-theme-light");
	};

	const applySignedInNavigation = (nativePage) => {
		const nativeProfile = nativePage.querySelector("[data-signed-in-username]");
		const login = nativeProfile?.getAttribute("data-signed-in-username")?.trim();
		if (!login) return;

		for (const element of document.querySelectorAll("[data-public-guest]")) {
			element.hidden = true;
		}
		for (const element of document.querySelectorAll("[data-public-auth]:not([data-public-admin])")) {
			element.hidden = false;
		}

		const home = document.querySelector("[data-public-home]");
		if (home) home.setAttribute("href", "/?home=1");

		const profile = document.querySelector("[data-public-profile]");
		if (profile) profile.setAttribute("href", `/${encodeURIComponent(login)}`);
		const starred = document.querySelector("[data-public-starred]");
		if (starred) starred.setAttribute("href", `/${encodeURIComponent(login)}?tab=stars`);
		for (const username of document.querySelectorAll("[data-public-username]")) {
			username.textContent = login;
		}

		const nativeAvatar = nativeProfile.querySelector(".navbar-avatar img, img");
		const avatar = document.querySelector("[data-public-avatar]");
		const avatarFallback = document.querySelector("[data-public-avatar-fallback]");
		if (nativeAvatar && avatar) {
			try {
				const avatarUrl = new URL(nativeAvatar.getAttribute("src") || "", window.location.origin);
				if (avatarUrl.origin === window.location.origin) {
					avatar.setAttribute("src", avatarUrl.pathname + avatarUrl.search);
					avatar.setAttribute("alt", `${login} avatar`);
					avatar.removeAttribute("hidden");
					if (avatarFallback) avatarFallback.setAttribute("hidden", "");
				}
			} catch {
				// Keep the local person glyph if Gitea returned an invalid avatar URL.
			}
		}

		// Show only the optional menu links that Gitea's own navbar offers this user.
		const nativeLinks = [...nativePage.querySelectorAll("#navbar a[href]")].map((link) => link.getAttribute("href"));
		for (const element of document.querySelectorAll("[data-public-native-href]")) {
			const suffix = element.getAttribute("data-public-native-href");
			element.hidden = !nativeLinks.some((href) => href.endsWith(suffix));
		}

		const nativeCount = nativePage.querySelector("#navbar .notification_count");
		const unread = nativeCount?.textContent.trim() || "";
		if (nativeCount && !nativeCount.classList.contains("tw-hidden") && /^[0-9]+\+?$/.test(unread)) {
			for (const badge of document.querySelectorAll("[data-public-notification-count]")) {
				badge.textContent = unread;
				badge.hidden = false;
			}
		}

		if (nativePage.querySelector('#navbar a[href="/-/admin"]')) {
			// removeAttribute, not .hidden: the avatar's admin badge is an SVG element, which has no
			// hidden property.
			for (const element of document.querySelectorAll("[data-public-admin]")) {
				element.removeAttribute("hidden");
			}
		}
		document.querySelector(".trueog-public-nav")?.classList.add("trueog-public-nav-authenticated");
	};

	// Start the session check at once, in parallel with parsing, and apply it once the navbar exists.
	void (async () => {
		try {
			const nativePage = await fetchNativePage();
			await domReady;
			if (nativePage) {
				applyTheme(nativePage);
				applySignedInNavigation(nativePage);
			}
		} finally {
			window.clearTimeout(revealTimer);
			revealNavigation();
		}
	})();

	document.addEventListener("toggle", (event) => {
		const opened = event.target;
		if (!(opened instanceof HTMLDetailsElement) || !opened.open) return;
		for (const menu of document.querySelectorAll(".trueog-public-menu[open]")) {
			if (menu !== opened) menu.removeAttribute("open");
		}
	}, true);
	document.addEventListener("click", (event) => {
		if (event.target instanceof Node && event.target.closest?.(".trueog-public-menu")) return;
		for (const menu of document.querySelectorAll(".trueog-public-menu[open]")) {
			menu.removeAttribute("open");
		}
	});
	document.addEventListener("keydown", (event) => {
		if (event.key !== "Escape") return;
		for (const menu of document.querySelectorAll(".trueog-public-menu[open]")) {
			menu.removeAttribute("open");
			menu.querySelector("summary")?.focus();
		}
	});

	// The pull lists' "Hide personal repositories" control is a link drawn as a checkbox. Links
	// already follow on Enter; Space toggles it too, as it would a native checkbox.
	document.addEventListener("keydown", (event) => {
		if (event.key !== " " || event.repeat) return;
		const control = event.target;
		if (!(control instanceof HTMLAnchorElement) || control.getAttribute("role") !== "checkbox") return;
		event.preventDefault();
		control.click();
	});

	// The phone navbar's menu toggle, as Gitea's own: it opens every item as a full-width row.
	const bindNavigationToggle = () => {
		const nav = document.querySelector(".trueog-public-nav");
		const toggle = document.querySelector("[data-public-nav-toggle]");
		if (!nav || !toggle) return;
		toggle.addEventListener("click", () => {
			const open = !nav.classList.contains("trueog-public-nav-open");
			nav.classList.toggle("trueog-public-nav-open", open);
			toggle.setAttribute("aria-expanded", String(open));
		});
	};
	void domReady.then(bindNavigationToggle);

	const bindContributionForms = () => {
		for (const form of document.querySelectorAll("[data-contribution-form]")) {
			const select = form.querySelector("select[name='target']");
			if (!select) continue;

			form.addEventListener("submit", (event) => {
				event.preventDefault();
				const repository = select.value;
				const submitter = event.submitter || form.querySelector("[data-target-suffix]");
				const suffix = submitter?.dataset.targetSuffix;
				const allowedSuffixes = new Set(["/pulls", "/fork", "/issues/new/choose"]);
				if (!repository || !repository.startsWith("/") || repository.startsWith("//")) return;
				if (!allowedSuffixes.has(suffix)) return;

				const destination = new URL(repository + suffix, window.location.origin);
				if (destination.origin !== window.location.origin) return;
				window.location.assign(destination.pathname + destination.search);
			});
		}
	};
	void domReady.then(bindContributionForms);
})();
