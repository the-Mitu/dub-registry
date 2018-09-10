/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module app;

import dubregistry.dbcontroller;
import dubregistry.mirror;
import dubregistry.repositories.bitbucket;
import dubregistry.repositories.github;
import dubregistry.repositories.gitlab;
import dubregistry.registry;
import dubregistry.web;
import dubregistry.api;

import std.algorithm : sort;
import std.process : environment;
import std.file;
import std.path;
import userman.web;
import vibe.d;


Task s_checkTask;
DubRegistry s_registry;
DubRegistryWebFrontend s_web;
string s_mirror;

void checkForNewVersions()
{
	if (s_mirror.length) s_registry.mirrorRegistry(s_mirror);
	else s_registry.updatePackages();
}

void startMonitoring()
{
	void monitorPackages()
	{
		sleep(1.seconds()); // give the cache a chance to warm up first
		while(true){
			checkForNewVersions;
			sleep(30.minutes());
		}
	}
	s_checkTask = runTask(&monitorPackages);
}

version (linux) private immutable string certPath;

shared static this()
{
	enum debianCA = "/etc/ssl/certs/ca-certificates.crt";
	enum redhatCA = "/etc/pki/tls/certs/ca-bundle.crt";
	immutable certPath = redhatCA.exists ? redhatCA : debianCA;
}

// generate dummy data for e.g. Heroku's preview apps
void defaultInit(UserManController userMan, DubRegistry registry)
{
	if (environment.get("GENERATE_DEFAULT_DATA", "0") == "1" &&
		registry.getPackageDump().empty)
	{
		logInfo("'GENERATE_DEFAULT_DATA' is set and an empty database has been detected. Inserting dummy data.");
		auto userId = userMan.registerUser("dummy@dummy.org", "dummyUser",
			"Dummy User", "test1234");
		DbRepository repo;
		repo.parseURL(URL("https://github.com/libmir/mir-optim"));
		registry.addPackage(repo, userId);
	}
}

void main()
{
	bool noMonitoring;
	setLogFile("log.txt", LogLevel.diagnostic);

	string hostname = "code.dlang.org";

	readOption("mirror", &s_mirror, "URL of a package registry that this instance should mirror (WARNING: will overwrite local database!)");
	readOption("hostname", &hostname, "Domain name of this instance (default: code.dlang.org)");
	readOption("no-monitoring", &noMonitoring, "Don't periodically monitor for updates (for local development)");

	// validate provided mirror URL
	if (s_mirror.length)
		validateMirrorURL(s_mirror);

	version (linux) {
		logInfo("Enforcing certificate trust.");
		//HTTPClient.setTLSSetupCallback((ctx) {
			//ctx.useTrustedCertificateFile(certPath);
			//ctx.peerValidationMode = TLSPeerValidationMode.trustedCert;
		//});
	}

	import dub.internal.utils : jsonFromFile;
	auto regsettingsjson = jsonFromFile(NativePath("settings.json"), true);
	auto ghuser = regsettingsjson["github-user"].opt!string;
	auto ghpassword = regsettingsjson["github-password"].opt!string;
	auto glurl = regsettingsjson["gitlab-url"].opt!string;
	auto glauth = regsettingsjson["gitlab-auth"].opt!string;
	auto bbuser = regsettingsjson["bitbucket-user"].opt!string;
	auto bbpassword = regsettingsjson["bitbucket-password"].opt!string;

	GithubRepository.register(ghuser, ghpassword);
	BitbucketRepository.register(bbuser, bbpassword);
	if (glurl.length) GitLabRepository.register(glauth, glurl);

	auto router = new URLRouter;
	if (s_mirror.length) router.any("*", (req, res) { req.params["mirror"] = s_mirror; });
	if (!noMonitoring)
		router.get("*", (req, res) @trusted { if (!s_checkTask.running) startMonitoring(); });

	// init mongo
	import dubregistry.mongodb : databaseName, mongoSettings;
	mongoSettings();

	// VPM registry
	auto regsettings = new DubRegistrySettings;
	regsettings.databaseName = databaseName;
	s_registry = new DubRegistry(regsettings);

	UserManController userdb;

	if (!s_mirror.length) {
		// user management
		auto udbsettings = new UserManSettings;
		udbsettings.serviceName = "DUB - The D package registry";
		udbsettings.serviceURL = URL("http://code.dlang.org/");
		udbsettings.serviceEmail = "noreply@vibed.org";
		udbsettings.databaseURL = environment.get("MONGODB_URI", environment.get("MONGO_URI", "mongodb://127.0.0.1:27017/vpmreg"));
		udbsettings.requireActivation = false;
		userdb = createUserManController(udbsettings);
	}

	// web front end
	s_web = router.registerDubRegistryWebFrontend(s_registry, userdb);
	router.registerDubRegistryAPI(s_registry);

	// check whether dummy data should be loaded
	defaultInit(userdb, s_registry);

	// start the web server
	auto settings = new HTTPServerSettings;
	settings.hostName = hostname;
	settings.bindAddresses = ["0.0.0.0", "127.0.0.1"];
	settings.port = 9095;
	settings.sessionStore = new MemorySessionStore;
	settings.useCompressionIfPossible = true;
	readOption("bind", &settings.bindAddresses[0], "Sets the address used for serving.");
	readOption("port|p", &settings.port, "Sets the port used for serving.");

	listenHTTP(settings, router);

	// poll github for new project versions
	if (!noMonitoring)
		startMonitoring();
	runApplication();
}
