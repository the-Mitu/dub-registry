/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.registry;

import dubregistry.dbcontroller;
import dubregistry.repositories.repository;

import dub.semver;
import std.algorithm : countUntil, filter, map, sort;
import std.array;
import std.encoding : sanitize;
import std.string : format, startsWith, toLower;
import std.typecons;
import vibe.data.bson;
import vibe.core.core;
import vibe.core.log;
import vibe.data.json;
import vibe.stream.operations;


/// Settings to configure the package registry.
class DubRegistrySettings {
	string databaseName = "vpmreg";
}

class DubRegistry {
	private {
		DubRegistrySettings m_settings;
		DbController m_db;
		Json[string] m_packageInfos;

		// list of package names to check for updates
		string[] m_updateQueue; // TODO: use a ring buffer
		string m_currentUpdatePackage;
		Task m_updateQueueTask;
		TaskMutex m_updateQueueMutex;
		TaskCondition m_updateQueueCondition;
	}

	this(DubRegistrySettings settings)
	{
		m_settings = settings;
		m_db = new DbController(settings.databaseName);
		m_updateQueueMutex = new TaskMutex;
		m_updateQueueCondition = new TaskCondition(m_updateQueueMutex);
		m_updateQueueTask = runTask(&processUpdateQueue);
	}

	@property auto availablePackages()
	{
		return m_db.getAllPackages();
	}

	void triggerPackageUpdate(string pack_name)
	{
		synchronized (m_updateQueueMutex) {
			if (!m_updateQueue.canFind(pack_name))
				m_updateQueue ~= pack_name;
		}
		if (!m_updateQueueTask.running)
			m_updateQueueTask = runTask(&processUpdateQueue);
		m_updateQueueCondition.notifyAll();
	}

	bool isPackageScheduledForUpdate(string pack_name)
	{
		if (m_currentUpdatePackage == pack_name) return true;
		synchronized (m_updateQueueMutex)
			if (m_updateQueue.canFind(pack_name)) return true;
		return false;
	}

	auto searchPackages(string[] keywords)
	{
		return m_db.searchPackages(keywords).map!(p => getPackageInfo(p.name));
	}

	void addPackage(Json repository, BsonObjectID user)
	{
		// find the packge info of ~master or any available branch
		PackageVersionInfo info;
		auto rep = getRepository(repository);
		auto branches = rep.getBranches();
		auto idx = branches.countUntil!(b => b[0] == "~master");
		try {
			if (idx >= 0)
				info = rep.getVersionInfo(branches[idx][1]);
		} catch {
			foreach (b; branches) {
				try {
					info = rep.getVersionInfo(b[1]);
					break;
				} catch {}
			}
		}
		enforce (info.info.type == Json.Type.object, "At least one branch of the repository must contain a package description file.");

		// derive package name and perform various sanity checks
		auto name = info.info.name.get!string;

		assert(info.info.license.opt!string.length > 0, `A "license" field in the package description file is missing or empty.`);
		assert(info.info.description.opt!string.length > 0, `A "description" field in the package description file is missing or empty.`);

		checkPackageName(name);
		foreach( string n, vspec; info.info.dependencies.opt!(Json[string]) )
			foreach (p; n.split(":"))
				checkPackageName(p);

		info.info.name = name.toLower();

		DbPackage pack;
		pack.owner = user;
		pack.name = info.info.name.get!string.toLower();
		pack.repository = repository;
		m_db.addPackage(pack);

		triggerPackageUpdate(pack.name);
	}

	void removePackage(string packname, BsonObjectID user)
	{
		logInfo("Removing package %s of %s", packname, user);
		m_db.removePackage(packname, user);
		if (packname in m_packageInfos) m_packageInfos.remove(packname);
	}

	auto getPackages(BsonObjectID user)
	{
		return m_db.getUserPackages(user);
	}

	Json getPackageInfo(string packname, bool include_errors = false)
	{
		if (!include_errors) {
			if (auto ppi = packname in m_packageInfos)
				return *ppi;
		}

		DbPackage pack;
		try pack = m_db.getPackage(packname);
		catch(Exception) return Json(null);

		auto rep = getRepository(pack.repository);

		Json[] vers;
		foreach( v; pack.branches ){
			auto nfo = v.info;
			nfo["version"] = v.version_;
			nfo.date = v.date.toSysTime().toISOExtString();
			nfo.url = rep.getDownloadUrl(v.version_); // obsolete, will be removed in april 2013
			nfo.downloadUrl = nfo.url; // obsolete, will be removed in april 2013
			vers ~= nfo;
		}
		foreach( v; pack.versions ){
			auto nfo = v.info;
			nfo["version"] = v.version_;
			nfo.date = v.date.toSysTime().toISOExtString();
			nfo.url = rep.getDownloadUrl("v" ~ v.version_); // obsolete, will be removed in april 2013
			nfo.downloadUrl = nfo.url; // obsolete, will be removed in april 2013
			vers ~= nfo;
		}

		Json ret = Json.emptyObject;
		ret.dateAdded = pack._id.timeStamp.toISOExtString();
		ret.name = packname;
		ret.versions = Json(vers);
		ret.repository = pack.repository;
		ret.categories = serializeToJson(pack.categories);
		if( include_errors ) ret.errors = serializeToJson(pack.errors);
		else m_packageInfos[packname] = ret;
		return ret;
	}

	void setPackageCategories(string pack_name, string[] categories)
	{
		m_db.setPackageCategories(pack_name, categories);
	}

	void checkForNewVersions()
	{
		logInfo("Triggering check for new versions...");
		foreach (packname; this.availablePackages)
			triggerPackageUpdate(packname);
	}

	protected bool addVersion(string packname, string ver, PackageVersionInfo info)
	{
		assert(ver.startsWith("~") && !ver.startsWith("~~") || isValidVersion(ver));

		logDiagnostic("Adding new version info %s for %s", ver, packname);

		// clear cached Json
		if (packname in m_packageInfos) m_packageInfos.remove(packname);

		info.info.name = toLower(info.info.name.get!string());
		enforce(info.info.name == packname, "Package name must match the original package name.");

		if ("description" !in info.info || "license" !in info.info) {
		//enforce("description" in info.info && "license" in info.info,
			throw new Exception(
			"Published packages must contain \"description\" and \"license\" fields.");
		}

		foreach( string n, vspec; info.info.dependencies.opt!(Json[string]) )
			foreach (p; n.split(":"))
				checkPackageName(p);

		DbPackageVersion dbver;
		dbver.date = BsonDate(info.date);
		dbver.version_ = ver;
		dbver.info = info.info;

		if (!ver.startsWith("~")) {
			if (m_db.hasVersion(packname, ver)) {
				m_db.updateVersion(packname, dbver);
				return false;
			}
			enforce(!m_db.hasVersion(packname, dbver.version_), "Version already exists.");
			if (auto pv = "version" in info.info)
				enforce("v"~pv.get!string == ver, format("Package description contains obsolete \"version\" field and does not match tag %s: %s", ver, pv.get!string));
			m_db.addVersion(packname, dbver);
		} else {
			if (m_db.hasBranch(packname, ver)) {
				m_db.updateBranch(packname, dbver);
				return false;
			}
			m_db.addBranch(packname, dbver);
		}
		return true;
	}

	protected void removeVersion(string packname, string ver)
	{
		assert(ver.startsWith("~") && !ver.startsWith("~~") || isValidVersion(ver));

		// clear cached Json
		if (packname in m_packageInfos) m_packageInfos.remove(packname);

		if (ver.startsWith("~")) m_db.removeBranch(packname, ver);
		else m_db.removeVersion(packname, ver);
	}

	private void processUpdateQueue()
	{
		while (true) {
			string pack;
			synchronized (m_updateQueueMutex) {
				while (m_updateQueue.empty)
					m_updateQueueCondition.wait();
				pack = m_updateQueue.front;
				m_updateQueue.popFront();
				m_currentUpdatePackage = pack;
			}
			scope(exit) m_currentUpdatePackage = null;
			try checkForNewVersions(pack);
			catch (Exception e) {
				logWarn("Failed to check versions for %s: %s", pack, e.msg);
				logDiagnostic("Full error: %s", e.toString().sanitize);
			}
		}
	}

	private void checkForNewVersions(string packname)
	{
		import std.encoding;
		string[] errors;

		Json pack;
		try pack = getPackageInfo(packname);
		catch( Exception e ){
			errors ~= format("Error getting package info: %s", e.msg);
			logDebug("%s", sanitize(e.toString()));
			return;
		}

		Repository rep;
		try rep = getRepository(pack.repository);
		catch( Exception e ){
			errors ~= format("Error accessing repository: %s", e.msg);
			logDebug("%s", sanitize(e.toString()));
			return;
		}

		bool[string] existing;
		Tuple!(string, CommitInfo)[] tags, branches;
		bool got_all_tags_and_branches = false;
		try {
			tags = rep.getTags()
				.filter!(a => a[0].startsWith("v") && a[0][1 .. $].isValidVersion)
				.array
				.sort!((a, b) => compareVersions(a[0][1 .. $], b[0][1 .. $]) < 0)
				.array;
			branches = rep.getBranches();
			got_all_tags_and_branches = true;
		} catch (Exception e) {
			errors ~= format("Failed to get GIT tags/branches: %s", e.msg);
		}
		foreach (tag; tags) {
			auto name = tag[0][1 .. $];
			existing[name] = true;
			try {
				if (addVersion(packname, name, rep.getVersionInfo(tag[1])))
					logInfo("Added version %s for %s", name, packname);
			} catch( Exception e ){
				logDebug("version %s", sanitize(e.toString()));
				errors ~= format("Version %s: %s", name, e.msg);
			}
		}
		foreach (branch; branches) {
			auto name = "~" ~ branch[0];
			existing[name] = true;
			try {
				if (addVersion(packname, name, rep.getVersionInfo(branch[1])))
					logInfo("Added branch %s for %s", name, packname);
			} catch( Exception e ){
				logDebug("%s", sanitize(e.toString()));
				errors ~= format("Branch %s: %s", name, e.msg);
			}
		}
		if (got_all_tags_and_branches) {
			foreach (v; pack.versions) {
				auto ver = v["version"].get!string;
				if (ver !in existing) {
					logInfo("Removing version %s as the branch/tag was removed.", ver);
					removeVersion(packname, ver);
				}
			}
		}
		m_db.setPackageErrors(packname, errors);
	}
}

private PackageVersionInfo getVersionInfo(Repository rep, CommitInfo commit)
{
	PackageVersionInfo ret;
	ret.date = commit.date.toSysTime();
	ret.sha = commit.sha;
	rep.readFile(commit.sha, Path("/package.json"), (scope input) {
		auto text = input.readAllUTF8(false);
		ret.info = parseJsonString(text);
	});
	return ret;
}

private void checkPackageName(string n){
	enforce(n.length > 0, "Package names may not be empty.");
	foreach( ch; n ){
		switch(ch){
			default:
				throw new Exception("Package names may only contain ASCII letters and numbers, as well as '_' and '-': "~n);
			case 'a': .. case 'z':
			case 'A': .. case 'Z':
			case '0': .. case '9':
			case '_', '-':
				break;
		}
	}
}

