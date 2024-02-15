import Controller from "@ember/controller";
import capabilities from "../utils/capabilities";
import i18n from "../utils/i18n";
import stashes from "../utils/_stashes";

export default Controller.extend({
  title: "Login",
  queryParams: ["jump_to_beta", "user_name", "device_key", "access_token"],
});
