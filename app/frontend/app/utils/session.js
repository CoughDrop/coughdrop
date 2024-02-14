import Ember from "ember";
import EmberObject from "@ember/object";
import { later as runLater, run } from "@ember/runloop";
import RSVP from "rsvp";
import $ from "jquery";
import stashes from "./_stashes";
import CoughDrop from "../app";
import capabilities from "./capabilities";
import persistence from "./persistence";
import coughDropExtras from "./extras";
import app_state from "./app_state";
import i18n from "./i18n";
import modal from "./modal";

var session = EmberObject.extend({
  setup: function (application) {
    application.register("cough_drop:session", session, {
      instantiate: false,
      singleton: true,
    });
    $.each(["model", "controller", "view", "route"], function (i, component) {
      application.inject(component, "session", "cough_drop:session");
    });
    CoughDrop.session = session;
  },
  persist: function (data) {
    session.set("auth_settings_fallback_data", data);
    var res = stashes.persist_object("auth_settings", data, true);
    res.then(
      function (r) {
        console.log("stashes.persist", r);
      },
      function (e) {
        console.error("stashes.persist", e);
      }
    );
    return res;
  },
  clear: function () {
    // only used for testing
    stashes.flush("auth_");
  },
  auth_settings_fallback: function () {
    if (session.get("auth_settings_fallback_data")) {
      console.error("auth settings stash lost mid-session");
      var res = session.get("auth_settings_fallback_data");
      if (res.user_name && res.user_name.match(/wahl/)) {
        session.alert("Session information lost unexpectedly");
      }
      return res;
    }
    return null;
  },
  confirm_authentication: function (response) {
    var promises = [];
    promises.push(
      session.persist({
        access_token: response.access_token,
        token_type: response.token_type,
        user_name: response.user_name,
        modeling_session: response.modeling_session,
        user_id: response.user_id,
      })
    );
    // update selfUserId, in the off chance that it has changed from our local copy
    // due to my user_name being renamed, and then me logging in to a new account
    // with the old user_name.
    if (response.user_id) {
      promises.push(
        persistence
          .store("settings", { id: response.user_id }, "selfUserId")
          .then(null, function () {
            return RSVP.reject({
              error: "selfUserId not persisted from login",
            });
          })
      );
    }
    stashes.persist("prior_login", "true");
    stashes.persist_object("just_logged_in", true, false);
    return RSVP.all_wait(promises).then(null, function () {
      return RSVP.resolve();
    });
  },
  hashed_password: function (password) {
    if (
      !window.crypto ||
      !window.crypto.subtle ||
      !window.crypto.subtle.digest
    ) {
      return RSVP.resolve(password);
    }
    return new RSVP.Promise(function (resolve, reject) {
      var str = "cdpassword:" + password + ":digested";
      window.crypto.subtle
        .digest("SHA-512", new TextEncoder().encode(str))
        .then(
          function (buffer) {
            var hashArray = Array.from(new Uint8Array(buffer));
            var hex = hashArray
              .map((b) => b.toString(16).padStart(2, "0"))
              .join("");
            var hashed_password = ["hashed", "sha512", hex].join("?:#");
            resolve(hashed_password);
          },
          function (err) {
            resolve(password);
          }
        );
    });
  },
  authenticate: function (credentials) {
    var _this = this;
    var res = new RSVP.Promise(function (resolve, reject) {
      var go = function (password) {
        var data = {
          grant_type: "password",
          client_id: "browser",
          client_secret: credentials.client_secret,
          username: credentials.identification,
          password: password,
          device_id: capabilities.device_id(),
          system_version: capabilities.system_version,
          system: capabilities.system,
          long_token: credentials.long_token,
          mobile: (!!capabilities.mobile).toString(),
        };

        persistence.ajax("/token", { method: "POST", data: data }).then(
          function (response) {
            if (response && response.auth_redirect) {
              return resolve({ redirect: response.auth_redirect });
            } else {
              session.confirm_authentication(response).then(function () {
                resolve(response);
              });
            }
          },
          function (data) {
            var xhr = data.fakeXHR || {};
            run(function () {
              reject(xhr.responseJSON || xhr.responseText);
            });
          }
        );
      };
      if (
        credentials.identification &&
        credentials.identification.match(/^model@/) &&
        credentials.password &&
        credentials.password.match(/\?:\#/)
      ) {
        // Modeling hashed passwords are already hashed, and
        // pre-hashing them messes up our confirmation
        go(credentials.password);
      } else {
        session.hashed_password(credentials.password).then(
          function (pw) {
            go(pw);
          },
          function (err) {
            go(credentials.password);
          }
        );
      }
    });
    res.then(null, function () {});
    return res;
  },
  jump_to_beta: function (credentials) {
    return persistence
      .ajax(
        "/jum_to_beta?user_name=" +
          credentials.user_name +
          "&device_key=" +
          credentials.device_key +
          "&access_token=" +
          credentials.access_token,
        {
          type: "GET",
        }
      )
      .then((resposnedata) => resposnedata)
      .catch((err) => {
        console.error("Unable to authenticate_beta", err);
      });
  },
  authenticate_classic: function (resposnedata) {
    var _this = this;
    var res = new RSVP.Promise(function (resolve, reject) {
      console.log("autheticate_beta in session");
      return session.confirm_authentication(resposnedata).then(function () {
        resolve(resposnedata);
      });
    });
    res.then(null, function () {});
    return res;
  },
  check_token: function (allow_invalidate) {
    var store_data =
      stashes.get_object("auth_settings", true) ||
      session.auth_settings_fallback() ||
      {};
    var key = store_data.access_token || "none";
    persistence.tokens = persistence.tokens || {};
    persistence.tokens[key] = true;
    var url =
      "/api/v1/token_check?access_token=" +
      store_data.access_token +
      "&rnd=" +
      Math.round(Math.random() * 999999);
    if (store_data.as_user_id) {
      url = url + "&as_user_id=" + store_data.as_user_id;
    }
    return persistence
      .ajax(url, {
        type: "GET",
      })
      .then(
        function (data) {
          // TODO: what happens if the session token gets invalidated mid-session (i.e. without reload?)
          // TODO: if expired, then re-submit with the refresh token
          if (data.authenticated === false) {
            session.set("invalid_token", true);
            if (allow_invalidate && store_data.access_token) {
              session.force_logout(
                i18n.t(
                  "session_token_invalid",
                  "This session has expired, please log back in"
                )
              );
              return { success: true };
            }
          } else {
            session.set("invalid_token", false);
          }
          if (data.user_name) {
            session.set("user_name", data.user_name);
            session.set("user_id", data.user_id);
            session.set("modeling_session", data.modeling_session);
            if (window.ga) {
              window.ga("set", "userId", data.user_id);
              window.ga("send", "event", "authentication", "user-id available");
            }
            if (app_state.get("sessionUser.id") != data.user_id) {
              runLater(function () {
                app_state.refresh_session_user();
              });
            }
          }
          if (data.sale !== undefined) {
            CoughDrop.sale = parseInt(data.sale, 10) || false;
          }
          if (data.ws_url) {
            stashes.persist("ws_url", data.ws_url);
          }
          if (data.global_integrations) {
            stashes.persist("global_integrations", data.global_integrations);
            if (window.user_preferences) {
              window.user_preferences.global_integrations =
                data.global_integrations;
            }
          }
          if (
            data.meta &&
            data.meta.fakeXHR &&
            data.meta.fakeXHR.browserToken
          ) {
            persistence.set("browserToken", data.meta.fakeXHR.browserToken);
          }
          return RSVP.resolve({
            success: true,
            browserToken: persistence.get("browserToken"),
          });
        },
        function (data) {
          if (!persistence.get("online")) {
            return { success: false };
          }
          if (data && data.fakeXHR && data.fakeXHR.browserToken) {
            persistence.set("browserToken", data.fakeXHR.browserToken);
          }
          if (data && data.result && data.result.error == "not online") {
            return { success: false };
          }
          if (!data && !persistence.get("online")) {
            return { success: false };
          }
          persistence.tokens[key] = false;
          return RSVP.resolve({
            success: false,
            browserToken: persistence.get("browserToken"),
          });
        }
      );
  },
  wait_for_token: function (popout_id) {
    return new RSVP.Promise(function (resolve, reject) {
      var started = new Date().getTime();
      var errors = 0;
      var check = function () {
        var now = new Date().getTime();
        if (now - started > 15 * 60 * 1000) {
          reject({ error: "timeout" });
        } else if (errors > 10) {
          reject({ error: "too many errors" });
        } else {
          var data = {
            popout_id: popout_id,
          };
          persistence.ajax("/wait/token", { method: "POST", data: data }).then(
            function (response) {
              if (response.error) {
                setTimeout(check, 500);
              } else {
                session.confirm_authentication(response).then(function () {
                  resolve(response);
                });
              }
            },
            function (err) {
              errors++;
              setTimeout(check, 2000);
            }
          );
        }
      };
      setTimeout(check, 1000);
    });
  },
  restore: function (force_check_for_token) {
    if (!stashes.get("enabled")) {
      return {};
    }
    console.debug("COUGHDROP: restoring session data");
    var store_data =
      stashes.get_object("auth_settings", true) ||
      session.auth_settings_fallback() ||
      {};
    var key = store_data.access_token || "none";
    persistence.tokens = persistence.tokens || {};
    if (store_data.access_token && !session.get("isAuthenticated")) {
      session.set("isAuthenticated", true);
      session.set("access_token", store_data.access_token);
      session.set("user_name", store_data.user_name);
      session.set("user_id", store_data.user_id);
      session.set("modeling_session", store_data.modeling_session);
      if (window.ga && store_data.user_id) {
        window.ga("set", "userId", store_data.user_id);
        window.ga("send", "event", "authentication", "user-id available");
      }
      session.set("as_user_id", store_data.as_user_id);
    } else if (!store_data.access_token) {
      // This should not run until stashes.db_connect has completed, so stashes has its
      // best chance to be populated.
      var any_proof_of_existing_login = Object.keys(store_data).length > 0;
      any_proof_of_existing_login =
        any_proof_of_existing_login ||
        stashes.fs_user_name ||
        (window.kvstash && window.kvstash.values && window.kvstash.user_name);
      var do_it = function () {
        if (any_proof_of_existing_login) {
          session.force_logout(
            i18n.t(
              "session_lost",
              "Session data has been lost, please log back in"
            )
          );
        } else {
          session.invalidate();
        }
      };
      if (any_proof_of_existing_login) {
        do_it();
      } else {
        stashes.get_db_id(capabilities).then(function (obj) {
          any_proof_of_existing_login =
            any_proof_of_existing_login || obj.db_id;
          do_it();
        });
      }
    }
    if (
      force_check_for_token ||
      (persistence.tokens[key] == null &&
        !Ember.testing &&
        persistence.get("online"))
    ) {
      if (store_data.access_token || force_check_for_token) {
        // || !persistence.get('browserToken')) {
        session.check_token(true);
      } else {
        session.set("tokenConfirmed", false);
      }
    }

    return store_data;
  },
  override: function (options) {
    var data = session.restore();
    data.access_token = options.access_token;
    data.user_name = options.user_name;
    data.user_id = options.user_id;
    stashes.flush().then(function () {
      stashes.setup();
      session.persist(data).then(function () {
        session.reload("/");
      });
    });
  },
  reload: function (path) {
    if (path) {
      if (Ember.testing) {
        console.error("would have redirected off the page");
      } else {
        if (capabilities.installed_app) {
          location.href = "#" + path;
          location.reload();
          if (window.navigator.splashscreen) {
            window.navigator.splashscreen.show();
          }
        } else {
          location.href = path;
        }
      }
    } else {
      location.reload();
    }
  },
  alert: function (message) {
    if (!Ember.testing) {
      alert(message);
    }
  },
  force_logout: function (message) {
    var full_invalidate = true; //!!(app_state.get('currentUser') || stashes.get_object('auth_settings', true) || session.auth_settings_fallback());
    if (full_invalidate) {
      if (!modal.route) {
        session.alert(message);
        session.invalidate(true);
      } else {
        modal.open("force-logout", { message: message });
      }
    } else {
      var store_data =
        stashes.get_object("auth_settings", true) ||
        session.auth_settings_fallback() ||
        {};
      if (
        (app_state.get("currentUser.user_name") || "").match(/wahl/) ||
        (store_data.user_name || "").match(/wahl/)
      ) {
        session.alert(message);
      }
      session.invalidate();
    }
  },
  invalidate: function (force) {
    var full_invalidate =
      force ||
      !!(
        app_state.get("currentUser") ||
        stashes.get_object("auth_settings", true) ||
        session.auth_settings_fallback()
      );
    if (full_invalidate) {
      if (window.navigator.splashscreen) {
        window.navigator.splashscreen.show();
      }
    }
    stashes
      .flush()
      .then(null, function () {
        return RSVP.resolve();
      })
      .then(function () {
        stashes.setup();
        var later = function (callback, delay) {
          callback();
        };
        if (!Ember.testing) {
          later = runLater;
        }

        // Give the session time to clear completely before reloading, otherwise they might
        // not actually get logged out
        later(function () {
          session.set("isAuthenticated", false);
          session.set("access_token", null);
          session.set(" ", null);
          session.set("user_id", null);
          session.set("as_user_id", null);
          if (full_invalidate) {
            later(function () {
              session.reload("/");
            });
          }
        });
      });
  },
}).create({});
window.session = session;

export default session;
