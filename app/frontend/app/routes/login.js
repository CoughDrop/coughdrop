import Route from "@ember/routing/route";
import session from "../utils/session";

export default Route.extend({
  title: "Login",
  model: function (params) {
    var _this = this;
    if (params.jump_to_beta === "true") {
      console.log("old-login-model jump_to_beta");
      return session.jump_to_beta(params);
    }
  },
  setupController: function (controller, model) {
    controller.set("model", model);
    controller.set("login_id", "");
    controller.set("login_password", "");
    if (location.search && location.search.match(/^\?model-/)) {
      var parts = decodeURIComponent(location.search.replace(/^\?/, "")).split(
        /:/
      );
      if (parts[0] && parts[1]) {
        controller.set(
          "login_id",
          parts[0].replace(/-/, "@").replace(/_/, ".")
        );
        controller.set("login_password", parts[1].replace(/-/, "?:#"));
        history.replaceState({}, null, "/login");
      }
    } else if (location.search && location.search.match(/^\?auth-/)) {
      var parts = location.search.replace(/^\?auth-/, "").split(/_/);
      var un = parts[1];
      var tmp_token = parts[0];
      controller.set("login_id", un);
      controller.set("tmp_token", tmp_token);
      history.replaceState({}, null, "/login");
    }
    if (session.get("isAuthenticated")) {
      // debugger;
    }
  },
});
