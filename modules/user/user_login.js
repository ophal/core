(function($) {

function login_request() {
  var user = $('#login_form #login_user').val();
  var date = new Date();
  var hash;
  /* Fetch auth token */
  $.ajax({
    type: 'GET',
    url: '/user/token',
    processData: false,
    success: function (token) {
      if (token) {
        hash = HMAC_SHA256_MAC(token, SHA256_hash($('#login_form #login_pass').val()));
        /* Authenticate */
        $.ajax({
          type: 'POST',
          url: '/user/auth',
          contentType: 'application/json; charset=utf-8',
          data: JSON.stringify({user: user, hash: hash}),
          dataType: 'json',
          processData: false,
          success: function(data) {
            if (data.authenticated) {
              window.location = '/';
            }
            else {
              alert('Wrong user/password.');
            }
          },
          error: function() {
            alert('Authentication error. Please try again later.');
          }
        });
      }
    }
  });
}

$(document).ready(function() {
  $('#login_submit').click(function() {
    try {
      login_request();
    } finally {
      /* Prevent browser to send POST request, since we already did it */
       return false;
    }
  });
});

})(jQuery);