import Controller from '@ember/controller';
import persistence from '../utils/persistence';
import i18n from '../utils/i18n';

export default Controller.extend({
  title: "Forgot Password",
  errorMsg:"",
  actions: {
    submitKey: function () {
      console.log("reset_password");
      var name = this.get("name");
      var _this = this;
      this.set("errorMsg", "");
      persistence
        .ajax("/api/v1/forgot_password", {
          type: "POST",
          data: { key: name },
        })
        .then(
          function (data) {
            _this.set("response", data);
          },
          function (xhr, message) {
            if (message && message.error == "not online") {
              _this.set("response", {
                message: i18n.t(
                  "email_not_sent_check_internet",
                  "Email not sent, please check your internet connection.",
                ),
              });
            } else if (xhr && xhr.result == "Too Many Requests") {
              _this.set("response", {
                message: i18n.t(
                  "request_throttled",
                  "Too many requests, please wait a few minutes and try again.",
                ),
              });
            } else if (xhr && xhr.result) {
              _this.set("response", {
                message: xhr.result,
              });
            } else {
              _this.set("response", {
                message: i18n.t(
                  "email_not_sent",
                  "Email not sent, there was an unexpected error.",
                ),
              });
            }
          },
        );
    }
  }
});
