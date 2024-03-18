import Controller from "@ember/controller";
import Subscription from "../../utils/subscription";
import modal from "../../utils/modal";
import i18n from "../../utils/i18n";
import persistence from "../../utils/persistence";
import app_state from "../../utils/app_state";
import progress_tracker from "../../utils/progress_tracker";
import { computed } from "@ember/object";

export default Controller.extend({
  queryParams: ["code", "confirmation"],
  code: null,
  confirmation: null,
  premium_symbols_enabled: computed(
    "model.subscription.extras_enabled",
    function () {
      return !!this.get("model.subscription.extras_enabled");
    }
  ),

  actions: {
    subscription_error: function (err) {
      modal.error(err);
    },
    subscription_success: function (msg) {
      modal.success(msg);
      this.get("subscription").reset();
    },
    premium_symbols: function (show) {
      this.set("show_premium_symbols", !!show);
    },
    refresh_subscription: function () {
      this.get("subscription").refresh_store(true);
    },
    manage_subscriptions: function () {
      this.get("subscription").manage_subscriptions();
    },
    purchase_premium_symbols: function () {
      var user = this.get("model");
      var _this = this;
      var subscribe = function (token) {
        _this.set("extras_status", { confirming: true });
        persistence
          .ajax("/api/v1/users/" + user.get("user_name") + "/subscription", {
            type: "POST",
            data: {
              token: token,
              type: "extras",
            },
          })
          .then(
            function (data) {
              progress_tracker.track(data.progress, function (event) {
                if (event.status == "errored") {
                  _this.set("extras_status", { error: true });
                } else if (
                  event.status == "finished" &&
                  event.result &&
                  event.result.success === false &&
                  event.result.error == "card_declined"
                ) {
                  _this.set("extras_status", { error: true, declined: true });
                } else if (event.result && event.result.success === false) {
                  _this.set("extras_status", { error: true });
                } else if (event.status == "finished") {
                  user.reload().then(
                    function () {
                      _this.set("extras_status", null);
                      _this.set("show_premium_symbols", false);
                      modal.success(
                        i18n.t(
                          "extras_purchased",
                          "Success! You now have access to premium symbols in %app_name%!"
                        )
                      );
                    },
                    function () {
                      _this.set("extras_status", {
                        error: true,
                        user_error: true,
                      });
                    }
                  );
                }
              });
            },
            function (err) {
              console.log(err);
              console.error("purchase_subscription_start_failed");
            }
          );
      };

      var subscription = Subscription.create({
        user: app_state.get("currentUser"),
      });
      subscription.set("user_type", "communicator");
      subscription.set("subscription_type", "extras");
      subscription.set("subscription_amount", "long_term_custom");
      subscription.set("subscription_custom_amount", 45);
      Subscription.purchase(subscription).then(function (result) {
        subscribe(result, subscription.get("subscription_custom_amount"));
      });
    },
    approve_or_reject_org: function (approve) {
      var user = this.get("model");
      var type = this.get("edit_permission") ? "add_edit" : "add";
      var _this = this;
      if (approve) {
        user.set("supervisor_key", "approve-org");
      } else {
        user.set("supervisor_key", "remove_supervisor-org");
      }
      user.save().then(
        function (user) {
          var sub = Subscription.create({ user: user });
          sub.reset();
          _this.set("subscription", sub);
        },
        function () {}
      );
    },
    reset: function () {
      this.get("subscription").reset();
    },
    show_options: function () {
      if (
        !app_state.get("installed_app") ||
        !this.get("subscription.no_purchasing")
      ) {
        this.set("subscription.show_options", true);
        this.set("subscription.show_cancel", false);
      }
    },
    // "frd" == "for reals, dude". See previous notes on the subject.
    cancel_subscription: function (frd) {
      var _this = this;
      var user = _this.get("model");
      if (frd) {
        this.set("subscription.canceling", true);
        var reason = _this.get("cancel_reason");
        persistence
          .ajax("/api/v1/users/" + user.get("user_name") + "/subscription", {
            type: "DELETE",
            data: {
              reason: reason,
            },
          })
          .then(
            function (data) {
              progress_tracker.track(data.progress, function (event) {
                if (event.status == "errored") {
                  modal.error(
                    i18n.t(
                      "user_subscription_cancel_failed",
                      "Subscription cancellation failed. Please try again or contact support for help."
                    )
                  );
                  console.log(event);
                } else if (event.status == "finished") {
                  modal.success(
                    i18n.t(
                      "user_subscription_canceled",
                      "Your subscription has been canceled."
                    )
                  );
                  user.reload().then(function () {
                    _this.send("reset");
                  });
                }
              });
            },
            function () {
              modal.error(
                i18n.t(
                  "user_subscription_cancel_failed",
                  "Subscription cancellation failed. Please try again or contact support for help."
                )
              );
            }
          );
      } else {
        this.set("subscription.show_options", true);
        this.set("subscription.show_cancel", true);
      }
    },
    show_expiration_notes: function () {
      this.set("show_expiration_notes", true);
    },
  },
});
