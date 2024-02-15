import Controller from "@ember/controller";
import persistence from "../../utils/persistence";
import { observer } from "@ember/object";
import { computed } from "@ember/object";

export default Controller.extend({
  title: "Reset Password",
  badPassword: {},
  checkPassword: observer("model.password", "model.password2", function () {
    var pw = this.get("model.password");
    var pw2 = this.get("model.password2");
    if (!this.get("badPassword")) {
      if (!pw || pw.length < 6 || pw != pw2) {
        this.set("badPassword", {});
      }
    }
    if (!pw) {
      this.set("badPassword.empty", true);
    } else if (pw.length < 6) {
      this.set("badPassword.short", true);
    } else if (pw != pw2) {
      this.set("badPassword.mismatch", true);
    } else {
      console.log("good one!");
      this.set("badPassword", null);
    }
  }),
  cantSubmit: computed("badPassword", "password_reset.succeeded", function () {
    this.checkPassword();
    return !!(this.get("badPassword") || this.get("password_reset.succeeded"));
  }),
  actions: {
    changePassword: function () {
      var user_name = this.get("model.user_name");
      if (this.get("badPassword")) {
        return;
      }
      var token = this.get("model.reset_token");
      var _this = this;
      this.set("password_reset", { pending: true });
      persistence
        .ajax("/api/v1/users/" + user_name, {
          type: "POST",
          data: {
            _method: "PUT",
            reset_token: token,
            user: {
              password: this.get("model.password"),
            },
          },
        })
        .then(
          function (data) {
            _this.set("password_reset.pending", false);
            _this.set("password_reset.succeeded", true);
          },
          function () {
            _this.set("password_reset.pending", false);
            _this.set("password_reset.failed", true);
          }
        );
    },
    authenticateSession: function () {
      this.transitionToRoute("login");
    },
  },
});
