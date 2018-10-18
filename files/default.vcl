#
# This is an example VCL file for Varnish.
#
# It does not do anything by default, delegating control to the
# builtin VCL. The builtin VCL is called when there is no explicit
# return statement.
#
# See the VCL chapters in the Users Guide at https://www.varnish-cache.org/docs/
# and https://www.varnish-cache.org/trac/wiki/VCLExamples for more examples.

# Marker to tell the VCL compiler that this VCL has been adapted to the
# new 4.0 format.
vcl 4.0;

# Remember, you can control the TTL for different content types by setting Cache-Control
# headers in .htaccess files (with mod_expires). Varnish defaults to 2 minutes.

# Helper functions
import std;

# Default backend definition. Set this to point to your content server.
backend default {
	.host = "127.0.0.1";
	.port = "80";
}

# ACL we'll use later to allow purges
acl purge {
	"localhost";
	"127.0.0.1";
}

sub vcl_recv {
	# Happens before we check if we have this in cache already.
	#
	# Typically you clean up the request here, removing cookies you don't need,
	# rewriting the request, etc.

	# Remove the proxy header (see https://httpoxy.org/#mitigate-varnish)
	unset req.http.proxy;

	# Normalize the query arguments (sort alphabetically)
	set req.url = std.querysort(req.url);

	# Strip a trailing ? if it exists
	if (req.url ~ "\?$") {
		set req.url = regsub(req.url, "\?$", "");
	}

	# Allow purging of single urls
	if (req.method == "PURGE") {
		if (!client.ip ~ purge) {
			return (synth(405, "This IP is not allowed to send PURGE requests."));
		}
		return (purge);
	}

	# Allow banning regexes
	if (req.method == "BAN") {
		if (!client.ip ~ purge) {
			return (synth(405, "This IP is not allowed to send BAN requests."));
		}
		ban("req.http.host == " + req.http.host + " && req.url ~ ^" + req.url);

		# Throw a synthetic page so the request won't go to the backend.
		return (synth(200, "Ban added"));
	}

	# Only deal with "normal" types
	if (req.method !~ "^GET|HEAD|PUT|POST|TRACE|OPTIONS|PATCH|DELETE$") {
		/* Non-RFC2616 or CONNECT which is weird. */
		return (pipe);
	}

	# Only cache GET or HEAD requests. This makes sure the POST requests are always passed, along w/ their cookies
	if (req.method != "GET" && req.method != "HEAD") {
		return (pass);
	}

	# Don't cache ajax requests
	if (req.http.X-Requested-With == "XMLHttpRequest") {
		return(pass);
	}

	# Don't cache images and PDFs. They aren't hard for Apache to serve up and consume memory to cache
	if (req.url ~ "\.(gif|jpg|jpeg|bmp|png|pdf)$") {
		return(pass);
	}

	# Not cacheable by default
	if (req.http.Authorization) {
		return (pass);
	}

	# Wordpress: don't cache users who are logged-in or on password-protected pages
	if (req.http.Cookie ~ "wordpress_logged_in_|resetpass|wp-postpass_") {
		return(pass);
	}

	# Wordpress: don't cache these special Wordpress pages
	if (req.url ~ "/feed(/)?|wp-admin|wp-(comments-post|cron|login|activate|mail)\.php|register\.php") {
		return (pass);
	}

	# Wordpress: don't cache search results
	if (req.url ~ "/\?s=") {
		return (pass);
	}

	# Wordpress: don't cache REST API (hand-rolled APIs used by custom themes)
	if (req.url ~ "/shared-gc/includes/rest-api/") {
		return (pass);
	}

	# Wordpress: don't cache anything with a cache-breaking v=<random> parameter (see gc.loadCachedJSON() JS function)
	if (req.url ~ "(\?|&)v=0") {
		return (pass);
	}

	# Don't cache the special pages we use to generate PDFs from the Wordpress catalog site
	if (req.url ~ "/generate-catalog/") {
		return (pass);
	}

	# Don't cache any large files (zip, audio, video, etc.)
	# Varnish does support streaming, but nginx will do it just as well
	if (req.url ~ "^[^?]*\.(7z|avi|bz2|flac|flv|gz|mka|mkv|mov|mp3|mp4|mpeg|mpg|ogg|ogm|opus|rar|tar|tgz|tbz|txz|wav|webm|wmv|xz|zip)(\?.*)?$") {
		return (pipe);
	}

	# Respect the browser's desire for a fresh copy on hard refresh
	# This ban will only work if there are no further URL changes (e.g. set req.url = ...) after it.
	if (req.http.Cache-Control == "no-cache") {
		ban("req.http.host == " + req.http.host + " && req.url == " + req.url);
	}

	# Remove all cookies to enable caching
	unset req.http.Cookie;

	return (hash);
}

sub vcl_hash {
	# The following url transformations help Varnish cache fewer
	# versions of the same content by ignoring marketing url parameters
	# and hashes.
	#
	# req.http.newUrl replaces req.url *for cache validation only*
	# Marketing parameters and hashes must still be sent to the backend
	# b/c even though they don't influence content, they should be included
	# in any redirects the backend generates.

	# Ignore marketing-related url parameters when caching urls
	# 	utm_ (Google Analytics)
	# 	gclid, cx, ie, cof, siteurl (not sure what these do)
	# 	gc_source (Goshen College internal campaign tracking)
	# 	mkt_tok (Marketo email click tracking)
	set req.http.newUrl = req.url;
	if (req.http.newUrl ~ "(\?|&)(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl|gc_source|mkt_tok)=") {
		set req.http.newUrl = regsuball(req.http.newUrl, "&(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl|gc_source|mkt_tok)=([A-z0-9_\-\.%25]+)", "");
		set req.http.newUrl = regsuball(req.http.newUrl, "\?(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl|gc_source|mkt_tok)=([A-z0-9_\-\.%25]+)", "?");
		set req.http.newUrl = regsub(req.http.newUrl, "\?&", "?");
		set req.http.newUrl = regsub(req.http.newUrl, "\?$", "");
	}

	# Ignore hash when caching urls
	if (req.http.newUrl ~ "\#") {
		set req.http.newUrl = regsub(req.http.newUrl, "\#.*$", "");
	}

	# Default vcl_hash, except replaced "req.url" with "req.http.newUrl"
	hash_data(req.http.newUrl);
	if (req.http.host) {
		hash_data(req.http.host);
	} else {
		hash_data(server.ip);
	}
	return (lookup);
}


sub vcl_backend_response {
	# Happens after we have read the response headers from the backend.
	#
	# Here you clean the response headers, removing silly Set-Cookie headers
	# and other mistakes your backend does.

	if (beresp.status == 301 || beresp.status == 302) {
		# Sometimes, a 301 or 302 redirect formed via Apache's mod_rewrite can mess with the HTTP port that is being passed along.
		# This often happens with simple rewrite rules in a scenario where Varnish runs on :80 and Apache on :8080 on the same box.
		# A redirect can then often redirect the end-user to a URL on :8080, where it should be :80.
		# This may need finetuning on your setup.
		#
		# To prevent accidental replace, we only filter the 301/302 redirects for now.
		set beresp.http.Location = regsub(beresp.http.Location, ":[0-9]+", "");

		# Don't cache redirects. Otherwise they're much more difficult to debug!
		set beresp.ttl = 0s;
	}

	# For debugging TTL
	# TTL should be the same as the Cache-Control header set by the Wordpress backend (in .htaccess mod_expires)
	# set beresp.http.test = beresp.ttl;

	# Allow stale content, in case the backend goes down.
	# make Varnish keep all objects for 6 hours beyond their TTL
	set beresp.grace = 6h;

	return(deliver);
}

sub vcl_deliver {
	# Happens when we have all the pieces we need, and are about to send the
	# response to the client.
	#
	# You can do accounting or modifying the final object here.

	# Add debug header to see if it's a HIT/MISS and the number of hits, disable when not needed
	if (obj.hits > 0) {
		set resp.http.X-Cache = "HIT";
	} else {
		set resp.http.X-Cache = "MISS";
	}

	# Please note that obj.hits behaviour changed in 4.0, now it counts per objecthead, not per object
	# and obj.hits may not be reset in some cases where bans are in use. See bug 1492 for details.
	# So take hits with a grain of salt
	set resp.http.X-Cache-Hits = obj.hits;

	# Remove some headers to improve security
	unset resp.http.X-Varnish;
	unset resp.http.Via;
	unset resp.http.X-Powered-By;
	unset resp.http.Server;
}
