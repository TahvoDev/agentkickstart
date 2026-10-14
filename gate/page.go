package main

// claimPage is the one-time claim UI served over TLS while the box is
// unclaimed. It is self-contained (no external assets) so it works offline.
const claimPage = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Set up agentbox</title>
<style>
:root{color-scheme:light dark}
body{margin:0;font:16px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#f5f5f7;color:#1c1c1e}
main{max-width:34rem;margin:0 auto;padding:2rem 1.25rem 4rem}
h1{font-size:1.5rem}
h2{font-size:1.2rem}
label{display:block;margin:.9rem 0 .2rem;font-weight:600}
input{width:100%;box-sizing:border-box;padding:.6rem .7rem;font:inherit;border:1px solid #c7c7cc;border-radius:.5rem}
button{margin-top:1rem;width:100%;padding:.7rem;font:inherit;font-weight:600;border:0;border-radius:.5rem;background:#0a84ff;color:#fff}
button.secondary{background:#8e8e93}
code,pre{display:block;background:#e9e9ee;padding:.6rem;border-radius:.4rem;word-break:break-all;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.85rem}
pre{white-space:pre-wrap}
#msg{color:#c0392b;font-weight:600;min-height:1.2em}
.hidden{display:none}
.note{color:#636366;font-size:.9rem}
a{color:#0a84ff}
</style>
</head>
<body>
<main>
<h1>Set up your agentbox</h1>

<div id="view-form">
  <p class="note">This page is served over a self-signed certificate. Compare its
  fingerprint with the one printed on the box console:</p>
  <code id="fp">{{FP}}</code>
  <form id="f" autocomplete="off">
    <label for="email">Owner email</label>
    <input id="email" value="owner@agentbox.local" autocomplete="username">
    <label for="pw">Password</label>
    <input id="pw" type="password" minlength="8" autocomplete="new-password">
    <label for="pw2">Confirm password</label>
    <input id="pw2" type="password" minlength="8" autocomplete="new-password">
    <label for="code">One-time code</label>
    <input id="code" autocomplete="one-time-code">
    <button>Set up agentbox</button>
  </form>
  <p id="msg"></p>
</div>

<div id="view-wait" class="hidden">
  <h2>Setting up…</h2>
  <p class="note">This can take a minute. Keep this page open.</p>
  <p id="step" class="note"></p>
</div>

<div id="view-error" class="hidden">
  <h2>Setup failed</h2>
  <pre id="err"></pre>
  <button id="retry" class="secondary">Try again</button>
</div>

<div id="view-done" class="hidden">
  <h2>All set</h2>
  <p>Vault: <a id="vurl" href="#"></a></p>
  <p>Owner: <span id="owner"></span></p>
  <p>Desktop password: <code id="dpw"></code></p>
  <p>Paseo password: <code id="ppw"></code></p>
  <p id="rkrow" class="hidden">Disk recovery key: <code id="rk"></code></p>
  <p class="note">Save these — they are also stored in the box's vault.</p>
  <p><a id="go" href="#">Open the vault &rarr;</a></p>
</div>
</main>
<script>
(function(){
  var $=function(id){return document.getElementById(id)};
  var views=["form","wait","error","done"];
  function show(v){views.forEach(function(x){$("view-"+x).classList.toggle("hidden",x!==v);})}
  var q=new URLSearchParams(location.search);
  if(q.get("code"))$("code").value=q.get("code");
  $("f").addEventListener("submit",function(e){
    e.preventDefault();
    var msg=$("msg"); msg.textContent="";
    if($("pw").value.length<8){msg.textContent="Password must be at least 8 characters.";return;}
    if($("pw").value!==$("pw2").value){msg.textContent="Passwords do not match.";return;}
    fetch("/claim",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({code:$("code").value,email:$("email").value,password:$("pw").value,password2:$("pw2").value})})
    .then(function(r){ if(r.status===202){show("wait");poll();} else { return r.text().then(function(t){msg.textContent=t;}); } })
    .catch(function(e){msg.textContent="Network error: "+e.message;});
  });
  $("retry").addEventListener("click",function(){$("msg").textContent="";show("form");});
  function poll(){
    fetch("/status").then(function(r){return r.json()}).then(function(s){
      if(s.state==="done"||s.state==="claimed"){
        fetch("/success").then(function(r){return r.ok?r.json():null}).then(function(d){
          var u=(d&&d.url)||(location.origin+"/");
          $("vurl").textContent=u; $("vurl").href=u; $("go").href=u;
          $("owner").textContent=(d&&d.email)||"";
          $("dpw").textContent=(d&&d.desktop_password)||"in the vault - run 'agentbox passphrase'";
          $("ppw").textContent=(d&&d.paseo_password)||"in the vault - run 'agentbox passphrase'";
          if(d&&d.recovery_key){$("rk").textContent=d.recovery_key;$("rkrow").classList.remove("hidden");}
          show("done");
        }).catch(function(){setTimeout(poll,1500)});
        return;
      }
      if(s.state==="error"){$("err").textContent=s.error||"unknown error";show("error");return;}
      if(s.step)$("step").textContent="step: "+s.step;
      setTimeout(poll,1500);
    }).catch(function(){setTimeout(poll,1500)});
  }
})();
</script>
</body>
</html>
`
