import Foundation
@testable import ActionsDev

/// Stateful fakes of gh, npx (skills CLI) and claude. State lives in files under the sandbox root
/// so tests can arrange it ("already signed in", "key already uploaded") and inspect it afterward.
extension DevSandbox {
    enum DeviceFlowBehavior: String {
        /// `! First copy your one-time code: 1A2B-C3D4`, then success.
        case code
        /// `! One-time code (ABCD-EF12) copied to clipboard`, then success.
        case clipboard
        /// Prints the code, then never finishes.
        case slow
        /// Prints the code, then `failed to authenticate via web browser: …`, exit 1.
        case fail
        /// Prints the code, then gives up the way gh does when the code expires: its own deadline, exit 1.
        case expire
        /// Prints the code, then GitHub's answer for an expired code, exit 1.
        case expiredToken = "expired-token"
        /// Prints the code, then the bare deadline error (no "failed to authenticate" prefix), exit 1.
        case bareExpire = "bare-expire"
    }

    var ghState: URL { root.appendingPathComponent("gh") }

    func installFakeGh(flow: DeviceFlowBehavior = .code, hostKeys: [String] = gitHubHostKeyLines) {
        try! FileManager.default.createDirectory(at: ghState, withIntermediateDirectories: true)
        directory.write("gh/flow", flow.rawValue)
        directory.write("gh/meta", hostKeys.joined(separator: "\n") + "\n")
        shim("gh", #"""
        state="$ROOT/gh"
        value_after() { local want="$1"; shift; local prev=""; for a in "$@"; do if [ "$prev" = "$want" ]; then echo "$a"; return; fi; prev="$a"; done; }
        host="$(value_after --hostname "$@")"
        case "$1" in
          auth)
            case "$2" in
              status)
                if [ -f "$state/login-$host" ]; then
                  printf '{"hosts":{"%s":[{"state":"success","active":true,"host":"%s","login":"shawntz","tokenSource":"keyring","scopes":"%s","gitProtocol":"%s"}]}}\n' \
                    "$host" "$host" "$(cat "$state/login-$host")" "$(cat "$state/protocol-$host" 2>/dev/null)"
                else
                  echo "You are not logged into any accounts on $host" >&2
                  echo '{"hosts":{}}'
                fi
                exit 0 ;;
              login|refresh)
                flow="$(cat "$state/flow")"
                echo "" >&2
                if [ "$flow" = clipboard ]; then
                  echo "! One-time code (ABCD-EF12) copied to clipboard" >&2
                else
                  echo "! First copy your one-time code: 1A2B-C3D4" >&2
                fi
                echo "Open this URL to continue in your web browser: https://$host/login/device" >&2
                if [ "$flow" = slow ]; then sleep 30; fi
                case "$flow" in
                  fail) echo "failed to authenticate via web browser: access_denied (access_denied)" >&2; exit 1 ;;
                  expire) echo "failed to authenticate via web browser: context deadline exceeded" >&2; exit 1 ;;
                  expired-token) echo "failed to authenticate via web browser: the device code has expired (expired_token)" >&2; exit 1 ;;
                  bare-expire) echo "context deadline exceeded" >&2; exit 1 ;;
                esac
                echo "✓ Authentication complete." >&2
                scopes="gist, read:org, repo"
                if [ "$2" = refresh ]; then scopes="$(cat "$state/login-$host")"; fi
                extra="$(value_after --scopes "$@")"
                if [ -n "$extra" ]; then scopes="$scopes, ${extra//,/, }"; fi
                echo "$scopes" > "$state/login-$host"
                protocol="$(value_after --git-protocol "$@")"
                if [ -n "$protocol" ]; then echo "$protocol" > "$state/protocol-$host"; fi
                echo "✓ Logged in as shawntz" >&2
                exit 0 ;;
              setup-git)
                git config --global --add "credential.https://$host.helper" ""
                git config --global --add "credential.https://$host.helper" "!$0 auth git-credential"
                exit 0 ;;
            esac ;;
          config)
            # gh config set --host H git_protocol P
            echo "$6" > "$state/protocol-$4"
            exit 0 ;;
          api)
            if [ ! -f "$state/login-$host" ]; then echo "HTTP 401: Bad credentials" >&2; exit 1; fi
            case "$*" in
              *user/ssh_signing_keys*) cat "$state/keys-signing" 2>/dev/null; exit 0 ;;
              *user/keys*) cat "$state/keys-authentication" 2>/dev/null; exit 0 ;;
              *meta*) cat "$state/meta"; exit 0 ;;
            esac ;;
          ssh-key)
            # gh ssh-key add PUB --type T --title TITLE (the host comes from GH_HOST)
            if [ -z "$GH_HOST" ]; then echo "GH_HOST was not set" >&2; exit 3; fi
            cut -d' ' -f1,2 "$3" >> "$state/keys-$5"
            echo "✓ Public key added to your account" >&2
            exit 0 ;;
        esac
        echo "unexpected gh call: $*" >&2
        exit 2
        """#)
    }

    /// Marks `host` as signed in with `scopes` (comma-space separated, as gh prints them).
    func ghSignedIn(_ host: String = "github.com", scopes: String = "admin:public_key, admin:ssh_signing_key, gist, read:org, repo", protocol gitProtocol: String = "ssh") {
        directory.write("gh/login-\(host)", scopes + "\n")
        directory.write("gh/protocol-\(host)", gitProtocol + "\n")
    }

    func ghRegisteredKeys(_ type: String) -> [String] {
        (directory.read("gh/keys-\(type)") ?? "").split(separator: "\n").map(String.init)
    }

    func installFakeNpx(createsLinks: Bool = true) {
        shim("npx", #"""
        name=""; agents=(); prev=""
        for a in "$@"; do
          if [ "$prev" = "-s" ]; then name="$a"; fi
          if [ "$prev" = "-a" ]; then agents+=("$a"); fi
          prev="$a"
        done
        mkdir -p "$HOME/.agents/skills/$name"
        printf -- '---\nname: %s\ndescription: fake upstream skill\n---\n' "$name" > "$HOME/.agents/skills/$name/SKILL.md"
        if [ "\#(createsLinks ? "yes" : "no")" = yes ]; then
          for agent in "${agents[@]}"; do
            case "$agent" in
              claude-code) mkdir -p "$HOME/.claude/skills"; ln -sfn "../../.agents/skills/$name" "$HOME/.claude/skills/$name" ;;
              grok) mkdir -p "$HOME/.grok/skills"; ln -sfn "../../.agents/skills/$name" "$HOME/.grok/skills/$name" ;;
            esac
          done
        fi
        echo "Installed 1 skill: $name"
        """#)
    }

    var claudeState: URL { root.appendingPathComponent("claude") }

    /// `plugins` lines are `id scope enabled`; `marketplaces` lines are `name repo`.
    func installFakeClaude(plugins: [String] = [], marketplaces: [String] = []) {
        directory.write("claude/plugins", plugins.map { $0 + "\n" }.joined())
        directory.write("claude/markets", marketplaces.map { $0 + "\n" }.joined())
        shim("claude", #"""
        s="$ROOT/claude"
        value_after() { local want="$1"; shift; local prev=""; for a in "$@"; do if [ "$prev" = "$want" ]; then echo "$a"; return; fi; prev="$a"; done; }
        case "$1 $2" in
          "plugin list")
            echo "Checking plugins..."
            printf '['; first=1
            while read -r id scope enabled; do
              [ -z "$id" ] && continue
              [ $first = 1 ] || printf ','; first=0
              printf '{"id":"%s","version":"1.0.0","scope":"%s","enabled":%s,"installPath":"/x","errors":[]}' "$id" "$scope" "$enabled"
            done < "$s/plugins"
            printf ']\n'
            exit 0 ;;
          "plugin marketplace")
            case "$3" in
              list)
                printf '['; first=1
                while read -r name repo; do
                  [ -z "$name" ] && continue
                  [ $first = 1 ] || printf ','; first=0
                  printf '{"name":"%s","source":"github","repo":"%s","installLocation":"/x"}' "$name" "$repo"
                done < "$s/markets"
                printf ']\n'
                exit 0 ;;
              add)
                repo="$4"; name="${repo#*/}"
                echo "$name $repo" >> "$s/markets"
                echo '{"outcome":"ok"}'
                exit 0 ;;
            esac ;;
          "plugin install")
            id="$3"; market="${id#*@}"; scope="$(value_after --scope "$@")"
            if ! grep -q "^$market " "$s/markets"; then
              echo "Plugin \"$id\" not found: marketplace \"$market\" is not known" >&2
              echo '{"outcome":"error"}'
              exit 1
            fi
            echo "$id $scope true" >> "$s/plugins"
            echo '{"outcome":"ok"}'
            exit 0 ;;
          "plugin enable")
            id="$3"
            sed -i '' "s/^$id \(.*\) false$/$id \1 true/" "$s/plugins"
            echo '{"outcome":"ok"}'
            exit 0 ;;
        esac
        echo "unexpected claude call: $*" >&2
        exit 2
        """#)
    }

    var claudePlugins: [String] {
        (directory.read("claude/plugins") ?? "").split(separator: "\n").map(String.init)
    }

    var claudeMarketplaces: [String] {
        (directory.read("claude/markets") ?? "").split(separator: "\n").map(String.init)
    }
}
