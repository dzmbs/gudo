//! `browser_upload`: files from this host into a page, only as the owner approved them.
//!
//! Before any file is read, the app shows the owner every file (path and size) and the origin
//! that receives them, on the device beside the page. Only after that approval are the files
//! read, each checked to be the one approved, and sent with the origin the approval named; the
//! app refuses an upload whose page moved to another origin. Paths resolve through the daemon's
//! [`PathPolicy`]: inside the agent's working tree only, and never keys, credentials,
//! keychains, browser profiles or this product's state, whatever the owner answers.

use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use daemon::PathPolicy;
use serde_json::{Value, json};

/// Most bytes one `browser_upload` sends: as base64 they must fit one frame to the app
/// (`proto::MAX_FRAME_LEN`).
pub const MAX_UPLOAD: usize = 3_000_000;

/// The app's tool that asks the owner to approve an upload; it answers with the origin approved.
pub const REVIEW_TOOL: &str = "browser_upload_review";

/// Under the home directory, never read for an upload.
const SECRET_PATHS: &[&str] = &[
    ".ssh",
    ".gnupg",
    ".password-store",
    ".aws",
    ".azure",
    ".config/gcloud",
    ".kube",
    ".docker/config.json",
    ".netrc",
    ".git-credentials",
    ".config/gh",
    ".npmrc",
    ".pypirc",
    ".cargo/credentials",
    ".cargo/credentials.toml",
    ".claude/.credentials.json",
    ".codex/auth.json",
    ".local/share/keyrings",
    ".mozilla",
    ".config/google-chrome",
    ".config/chromium",
    ".config/BraveSoftware",
    ".config/microsoft-edge",
    "snap/firefox",
    "snap/chromium",
    "Library/Keychains",
    "Library/Cookies",
    "Library/Safari",
    "Library/Containers/com.apple.Safari",
    "Library/Application Support/Google/Chrome",
    "Library/Application Support/Chromium",
    "Library/Application Support/BraveSoftware",
    "Library/Application Support/Microsoft Edge",
    "Library/Application Support/Arc",
    "Library/Application Support/Firefox",
    "Library/Application Support/com.operasoftware.Opera",
];

/// Outside the home directory, never read for an upload.
const SECRET_SYSTEM_PATHS: &[&str] = &["/Library/Keychains", "/etc/ssh", "/etc/shadow"];

/// Where `browser_upload` may read on this host.
pub struct UploadScope {
    policy: PathPolicy,
    home: PathBuf,
    cwd: PathBuf,
    tree: PathBuf,
}

impl UploadScope {
    /// The scope of this process: its working tree, this user's secrets and the product's
    /// state refused.
    pub fn current() -> Self {
        let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from);
        let cwd = std::env::current_dir().unwrap_or_else(|_| home.clone());
        let state_dirs = [
            daemon::default_state_dir(),
            home.join(".config").join(brand::DIR_NAME),
            home.join(".config").join(brand::legacy::DIR_NAME),
            home.join(".local/state").join(brand::legacy::DIR_NAME),
            home.join("Library/Application Support")
                .join(brand::legacy::DIR_NAME),
        ];
        Self::new(&home, &cwd, &state_dirs)
    }

    /// Files inside `cwd`'s working tree (its git checkout, else `cwd`), less the secrets
    /// under `home` and `state_dirs`.
    pub fn new(home: &Path, cwd: &Path, state_dirs: &[PathBuf]) -> Self {
        let tree = working_tree(cwd, home);
        let mut policy = PathPolicy::confined(home, std::slice::from_ref(&tree));
        for secret in SECRET_PATHS {
            policy = policy.refuse(&home.join(secret));
        }
        for secret in SECRET_SYSTEM_PATHS {
            policy = policy.refuse(Path::new(secret));
        }
        for dir in state_dirs {
            policy = policy.refuse(dir);
        }
        Self {
            policy,
            home: home.canonicalize().unwrap_or_else(|_| home.to_owned()),
            cwd: cwd.to_owned(),
            tree,
        }
    }

    /// The real path of `raw` (relative to the working directory, `~/` or absolute), if this
    /// scope allows reading it.
    fn resolve(&self, raw: &str) -> Result<PathBuf, String> {
        let spelled = if raw == "~" || raw.starts_with("~/") || Path::new(raw).is_absolute() {
            raw.to_owned()
        } else {
            self.cwd.join(raw).to_string_lossy().into_owned()
        };
        let refused = || {
            format!(
                "{raw} cannot be uploaded: browser_upload reads files inside {} only, and never keys, credentials, keychains, browser profiles or {} state",
                self.shown(&self.tree),
                brand::PRODUCT_NAME
            )
        };
        let path = self
            .policy
            .resolve_followed(&spelled)
            .map_err(|_| refused())?;
        let real = path
            .canonicalize()
            .map_err(|io_error| format!("{raw}: {io_error}"))?;
        // The real path again, so a link swapped in after the check is caught too.
        self.policy
            .resolve(&real.to_string_lossy())
            .map_err(|_| refused())?;
        Ok(real)
    }

    /// `path` with the home directory as `~`.
    fn shown(&self, path: &Path) -> String {
        match path.strip_prefix(&self.home) {
            Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
            Ok(rest) => format!("~/{}", rest.display()),
            Err(_) => path.display().to_string(),
        }
    }
}

/// `cwd`'s git checkout, else `cwd`; never above the home directory.
fn working_tree(cwd: &Path, home: &Path) -> PathBuf {
    let cwd = cwd.canonicalize().unwrap_or_else(|_| cwd.to_owned());
    let home = home.canonicalize().unwrap_or_else(|_| home.to_owned());
    if cwd != home && home.starts_with(&cwd) {
        return home;
    }
    cwd.ancestors()
        .take_while(|dir| !home.starts_with(dir))
        .find(|dir| dir.join(".git").exists())
        .unwrap_or(&cwd)
        .to_owned()
}

/// A file on this host, as the owner approves it.
struct HostFile {
    path: PathBuf,
    shown: String,
    name: String,
    size: u64,
    identity: (u64, u64),
}

impl HostFile {
    /// The file's bytes, if it is still the one approved.
    fn read(&self) -> Result<Vec<u8>, String> {
        let changed = || format!("{} changed after it was approved", self.shown);
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&self.path)
            .map_err(|io_error| format!("{}: {io_error}", self.shown))?;
        let meta = file
            .metadata()
            .map_err(|io_error| format!("{}: {io_error}", self.shown))?;
        if (meta.dev(), meta.ino()) != self.identity || meta.len() != self.size {
            return Err(changed());
        }
        let mut bytes = Vec::new();
        (&mut file)
            .take(self.size + 1)
            .read_to_end(&mut bytes)
            .map_err(|io_error| format!("{}: {io_error}", self.shown))?;
        if bytes.len() as u64 != self.size {
            return Err(changed());
        }
        Ok(bytes)
    }
}

/// What one `browser_upload` sends, before the owner approved it.
pub struct Upload {
    inline: Vec<Value>,
    inline_sizes: Vec<usize>,
    host: Vec<HostFile>,
}

fn too_big(what: &str) -> String {
    format!(
        "{what} takes the upload past {} MB, the most one call carries",
        MAX_UPLOAD / 1_000_000
    )
}

impl Upload {
    /// Checks `args`' `files` (inline) and `paths` (on this host) without reading any file:
    /// each path allowed by `scope`, a regular file, all within [`MAX_UPLOAD`] bytes.
    pub fn plan(args: &Value, scope: &UploadScope) -> Result<Self, String> {
        let mut inline = match args.get("files") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(files)) => files.clone(),
            Some(_) => return Err("`files` is a list".into()),
        };
        let mut total = 0;
        let mut inline_sizes = Vec::new();
        for file in &mut inline {
            let data = file["data"]
                .as_str()
                .ok_or("each of `files` needs name and data (base64)")?;
            let size = STANDARD
                .decode(data)
                .map_err(|decode_error| format!("bad base64: {decode_error}"))?
                .len();
            let name = file["name"]
                .as_str()
                .ok_or("each of `files` needs a name")?
                .to_owned();
            total += size;
            if total > MAX_UPLOAD {
                return Err(too_big(&name));
            }
            if file["mime_type"].as_str().is_none_or(str::is_empty) {
                file["mime_type"] = json!(crate::browser_tools::mime_for(&name));
            }
            inline_sizes.push(size);
        }
        let paths = match args.get("paths") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::String(one)) => vec![one.clone()],
            Some(Value::Array(paths)) => paths
                .iter()
                .map(|path| {
                    path.as_str()
                        .map(str::to_owned)
                        .ok_or("`paths` are strings")
                })
                .collect::<Result<_, _>>()?,
            Some(_) => return Err("`paths` is a list of paths".into()),
        };
        let mut host = Vec::new();
        for raw in paths {
            let path = scope.resolve(&raw)?;
            let shown = scope.shown(&path);
            let meta = std::fs::metadata(&path).map_err(|io_error| format!("{raw}: {io_error}"))?;
            if !meta.is_file() {
                return Err(format!("{raw} is not a file"));
            }
            total += usize::try_from(meta.len()).unwrap_or(usize::MAX);
            if total > MAX_UPLOAD {
                return Err(too_big(&format!(
                    "{shown} ({:.1} MB)",
                    meta.len() as f64 / 1e6
                )));
            }
            let name = path.file_name().map_or_else(
                || shown.clone(),
                |file_name| file_name.to_string_lossy().into_owned(),
            );
            host.push(HostFile {
                identity: (meta.dev(), meta.ino()),
                size: meta.len(),
                path,
                shown,
                name,
            });
        }
        Ok(Self {
            inline,
            inline_sizes,
            host,
        })
    }

    pub fn is_empty(&self) -> bool {
        self.inline.is_empty() && self.host.is_empty()
    }

    /// What the owner is asked to approve: each file's name, size and, for files on this host,
    /// path; never their contents.
    pub fn review(&self, target: Option<&Value>) -> Value {
        let inline = self
            .inline
            .iter()
            .zip(&self.inline_sizes)
            .map(|(file, size)| json!({ "name": file["name"], "size": size }));
        let host = self
            .host
            .iter()
            .map(|file| json!({ "name": file.name, "path": file.shown, "size": file.size }));
        let mut review = json!({ "files": inline.chain(host).collect::<Vec<_>>() });
        if let Some(target) = target {
            review["target"] = target.clone();
        }
        review
    }

    /// The files as the app takes them (`{name, mime_type, data}`), reading the host files now.
    pub fn read(self) -> Result<Vec<Value>, String> {
        let mut files = self.inline;
        for file in &self.host {
            let bytes = file.read()?;
            files.push(json!({
                "name": file.name,
                "mime_type": crate::browser_tools::mime_for(&file.name),
                "data": STANDARD.encode(&bytes),
            }));
        }
        Ok(files)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture {
        _root: tempfile::TempDir,
        home: PathBuf,
        project: PathBuf,
        state: PathBuf,
    }

    fn fixture() -> Fixture {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().canonicalize().unwrap().join("me");
        let project = home.join("code/app");
        let state = home.join("Library/Application Support/Gudo");
        for dir in [
            project.join(".git"),
            project.join("assets"),
            home.join(".ssh"),
            home.join(".aws"),
            home.join("Downloads"),
            state.clone(),
        ] {
            std::fs::create_dir_all(dir).unwrap();
        }
        std::fs::write(project.join("assets/logo.png"), "png").unwrap();
        std::fs::write(home.join(".ssh/id_ed25519"), "PRIVATE KEY").unwrap();
        std::fs::write(home.join(".aws/credentials"), "secret").unwrap();
        std::fs::write(home.join("Downloads/invoice.pdf"), "pdf").unwrap();
        std::fs::write(state.join("hook.token"), "token").unwrap();
        Fixture {
            _root: root,
            home,
            project,
            state,
        }
    }

    fn scope(fixture: &Fixture, cwd: &Path) -> UploadScope {
        UploadScope::new(&fixture.home, cwd, std::slice::from_ref(&fixture.state))
    }

    fn plan(scope: &UploadScope, path: &str) -> Result<Upload, String> {
        Upload::plan(&json!({ "paths": [path] }), scope)
    }

    #[test]
    fn files_in_the_working_tree_are_planned_unread() {
        let fixture = fixture();
        let scope = scope(&fixture, &fixture.project.join("assets"));
        let upload = plan(&scope, "logo.png").unwrap();
        assert_eq!(
            upload.review(None),
            json!({ "files": [{ "name": "logo.png", "path": "~/code/app/assets/logo.png", "size": 3 }] })
        );
        assert!(plan(&scope, "~/code/app/assets/logo.png").is_ok());
        assert!(plan(&scope, "../assets/logo.png").is_err(), "no ..");
        let files = upload.read().unwrap();
        assert_eq!(files[0]["data"], "cG5n");
        assert_eq!(files[0]["mime_type"], "image/png");
    }

    #[test]
    fn secrets_and_files_outside_the_tree_are_refused() {
        let fixture = fixture();
        let scope = scope(&fixture, &fixture.project);
        for path in [
            "~/.ssh/id_ed25519",
            "~/.aws/credentials",
            "~/Downloads/invoice.pdf",
            "/etc/hosts",
        ] {
            let why = plan(&scope, path).err().unwrap_or_default();
            assert!(why.contains("cannot be uploaded"), "{path}: {why}");
        }
        let state_file = fixture.state.join("hook.token");
        assert!(plan(&scope, &state_file.to_string_lossy()).is_err());

        // A link in the tree to a secret is refused through its target.
        std::os::unix::fs::symlink(
            fixture.home.join(".ssh/id_ed25519"),
            fixture.project.join("key"),
        )
        .unwrap();
        assert!(plan(&scope, "key").is_err());
    }

    #[test]
    fn secrets_stay_refused_whatever_the_working_directory() {
        let fixture = fixture();
        for cwd in [
            fixture.home.clone(),
            fixture.home.join(".ssh"),
            PathBuf::from("/"),
        ] {
            let scope = scope(&fixture, &cwd);
            assert!(plan(&scope, "~/.ssh/id_ed25519").is_err(), "{cwd:?}");
            assert!(plan(&scope, "~/.aws/credentials").is_err(), "{cwd:?}");
        }
        // Started at home, the tree is home; never above it.
        let scope = scope(&fixture, Path::new("/"));
        assert!(plan(&scope, "~/Downloads/invoice.pdf").is_ok());
        assert!(plan(&scope, "/etc/hosts").is_err());
    }

    #[test]
    fn a_file_that_changed_after_approval_is_not_sent() {
        let fixture = fixture();
        let scope = scope(&fixture, &fixture.project);
        let upload = plan(&scope, "assets/logo.png").unwrap();
        std::fs::write(fixture.project.join("assets/logo.png"), "longer").unwrap();
        assert!(upload.read().unwrap_err().contains("changed"));

        let upload = plan(&scope, "assets/logo.png").unwrap();
        std::fs::remove_file(fixture.project.join("assets/logo.png")).unwrap();
        std::fs::write(fixture.project.join("assets/other"), "abcdef").unwrap();
        std::fs::rename(
            fixture.project.join("assets/other"),
            fixture.project.join("assets/logo.png"),
        )
        .unwrap();
        assert!(upload.read().is_err());
    }

    #[test]
    fn inline_files_and_paths_share_the_cap() {
        let fixture = fixture();
        let scope = scope(&fixture, &fixture.project);
        let upload = Upload::plan(
            &json!({ "files": [{ "name": "pic.PNG", "data": "AAEC" }], "paths": "assets/logo.png" }),
            &scope,
        )
        .unwrap();
        assert_eq!(
            upload.review(Some(&json!({ "type": "ref", "ref": "ref_2" }))),
            json!({
                "files": [
                    { "name": "pic.PNG", "size": 3 },
                    { "name": "logo.png", "path": "~/code/app/assets/logo.png", "size": 3 },
                ],
                "target": { "type": "ref", "ref": "ref_2" },
            })
        );
        let files = upload.read().unwrap();
        assert_eq!(files[0]["mime_type"], "image/png");

        let big = fixture.project.join("big.bin");
        std::fs::write(&big, vec![0u8; MAX_UPLOAD + 1]).unwrap();
        let why = plan(&scope, "big.bin").err().unwrap();
        assert!(why.contains("past 3 MB"), "{why}");
        let half = fixture.project.join("half.bin");
        std::fs::write(&half, vec![0u8; MAX_UPLOAD / 2 + 1]).unwrap();
        assert!(Upload::plan(&json!({ "paths": ["half.bin", "half.bin"] }), &scope).is_err());
        assert!(plan(&scope, "missing").is_err());
        assert!(plan(&scope, "assets").err().unwrap().contains("not a file"));
        let bad = |files: Value| {
            Upload::plan(&json!({ "files": files }), &scope)
                .err()
                .unwrap()
        };
        assert!(bad(json!([{ "data": "AA==" }])).contains("name"));
        assert!(bad(json!([{ "name": "a", "data": "!!" }])).contains("base64"));
    }
}
