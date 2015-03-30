/**
 * Ophal jQuery library.
 */

(function($) {window.Ophal = new function(namespace, func) {

this.settings = {};

this.set_message = function(message) {
  var message = $('<div class="error-message">' + message + '</div>');
  $(message).click(function () {
    if (confirm('Do you wish to hide this message?')) {
      $(this).remove();
    }
  });
  $('#messages').append(message);
};

this.extend = function (namespace, func) {
  (this[namespace] = func)($);
};

this.scroll_down = function() {
  if (window.location.href.split('#')[1]) {
    window.location = window.location;
  }
};

this.post = function(config) {
  return $.ajax({
    type: 'POST',
    url: this.settings.core.base.route + config.url,
    contentType: 'application/json; charset=utf-8',
    data: JSON.stringify(config.data),
    dataType: 'json',
    processData: false,
    success: config.success,
    error: config.error
  });
};

this.progress = function(selector, value) {
  $(selector + ' .progress .meter').css('width', value + '%');
};

this.t = function(value) {
  if ('locale' in this.settings && this.settings.locale[value]) {
    return this.settings.locale[value];
  }

  return value;
}

}})(jQuery);
