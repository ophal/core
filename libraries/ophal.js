/**
 * Ophal jQuery library.
 */

(function($) {

var Ophal = {};

window.Ophal = Ophal;

Ophal.set_message = function(message) {
  var message = $('<div class="error-message">' + message + '</div>');
  $(message).click(function () {
    if (confirm('Do you wish to hide this message?')) {
      $(this).remove();
    }
  });
  $('#messages').append(message);
};

})(jQuery);