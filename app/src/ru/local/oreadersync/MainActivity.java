package ru.local.oreadersync;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.os.Bundle;
import android.os.Handler;
import android.text.InputType;
import android.util.TypedValue;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.HashMap;
import java.util.Map;

public class MainActivity extends Activity {

    private static final String SCRIPT = "sh /data/local/tmp/kosync.sh ";
    private static final String CONF_DIR = "/sdcard/oreader-kosync";
    private static final String CONF = CONF_DIR + "/kosync.conf";

    private TextView info;
    private TextView status;
    private Button pushBtn;
    private Button pullBtn;
    private Button settingsBtn;
    private final Handler ui = new Handler();
    private final Map<String, String> server = new HashMap<String, String>();
    private boolean busy;

    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);

        int pad = (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 14,
                getResources().getDisplayMetrics());

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText("Синхронизация чтения");
        title.setTextSize(20);
        title.setPadding(0, 0, 0, pad);
        root.addView(title);

        info = new TextView(this);
        info.setTextSize(16);
        info.setText("Читаю прогресс с сервера...");
        info.setPadding(0, 0, 0, pad);
        root.addView(info);

        pushBtn = new Button(this);
        pushBtn.setText("Отправить локальный прогресс на Xteink X4");
        pushBtn.setTextSize(17);
        pushBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                confirmRun("push");
            }
        });
        root.addView(pushBtn);

        pullBtn = new Button(this);
        pullBtn.setText("Загрузить прогресс с Xteink X4");
        pullBtn.setTextSize(17);
        pullBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                confirmRun("pull");
            }
        });
        root.addView(pullBtn);

        settingsBtn = new Button(this);
        settingsBtn.setText("Настройки сервера");
        settingsBtn.setTextSize(17);
        settingsBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                openSettings();
            }
        });
        root.addView(settingsBtn);

        status = new TextView(this);
        status.setTextSize(14);
        status.setText("Готово к работе.");
        status.setPadding(0, pad, 0, 0);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(status);
        root.addView(scroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        setContentView(root);
        refresh();
    }

    private String runScript(String mode) {
        StringBuilder out = new StringBuilder();
        try {
            Process p = Runtime.getRuntime().exec(new String[] { "su", "-c", SCRIPT + mode });
            BufferedReader in = new BufferedReader(new InputStreamReader(p.getInputStream()));
            String line;
            while ((line = in.readLine()) != null) {
                out.append(line).append('\n');
            }
            BufferedReader err = new BufferedReader(new InputStreamReader(p.getErrorStream()));
            while ((line = err.readLine()) != null) {
                out.append(line).append('\n');
            }
            p.waitFor();
        } catch (Exception ex) {
            out.append("ОШИБКА: ").append(String.valueOf(ex)).append('\n');
        }
        return out.toString().trim();
    }

    private void refresh() {
        setBusy(true, "Читаю прогресс с сервера...");
        new Thread(new Runnable() {
            public void run() {
                final String out = runScript("server");
                ui.post(new Runnable() {
                    public void run() {
                        showServer(out);
                        setBusy(false, null);
                    }
                });
            }
        }).start();
    }

    private void showServer(String out) {
        server.clear();
        String[] lines = out.split("\n");
        for (int i = 0; i < lines.length; i++) {
            int eq = lines[i].indexOf('=');
            if (eq > 0) {
                server.put(lines[i].substring(0, eq).trim(), lines[i].substring(eq + 1).trim());
            }
        }

        String book = server.get("book");
        StringBuilder sb = new StringBuilder();
        if (book == null) {
            sb.append("Не удалось прочитать данные сервера.\n").append(out);
            info.setText(sb.toString());
            return;
        }

        sb.append("Книга: ").append(book).append('\n');
        sb.append("Локально: ").append(fmtPct(server.get("local"))).append('\n');

        String remote = server.get("server");
        if (remote == null || remote.length() == 0) {
            sb.append("На сервере: записи нет");
        } else {
            sb.append("На сервере: ").append(fmtPct(remote));
            String device = server.get("device");
            if (device != null && device.length() > 0) {
                sb.append(" (").append(device).append(')');
            }
            String ts = server.get("time");
            if (ts != null && ts.length() > 0) {
                try {
                    long t = Long.parseLong(ts) * 1000L;
                    sb.append('\n').append("Записано: ").append(
                            new SimpleDateFormat("dd.MM HH:mm").format(new Date(t)));
                } catch (Exception ignored) {
                }
            }
        }
        info.setText(sb.toString());
    }

    private String fmtPct(String value) {
        if (value == null || value.length() == 0) {
            return "—";
        }
        return value.replace('.', ',') + "%";
    }

    private void confirmRun(final String mode) {
        if (busy) {
            return;
        }
        String remote = server.get("server");
        String local = server.get("local");
        String device = server.get("device");
        String text;
        if ("push".equals(mode)) {
            text = "Отправить на сервер локальную позицию " + fmtPct(local) + "?";
        } else {
            text = "На сервере: " + fmtPct(remote)
                    + (device == null || device.length() == 0 ? "" : " (" + device + ")")
                    + "\nЛокально: " + fmtPct(local)
                    + "\n\nЗаменить локальную позицию серверной?";
        }
        new AlertDialog.Builder(this)
                .setTitle("push".equals(mode) ? "Отправка на сервер" : "Загрузка с сервера")
                .setMessage(text)
                .setPositiveButton("Да", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int w) {
                        runMode(mode);
                    }
                })
                .setNegativeButton("Отмена", null)
                .show();
    }

    private void runMode(final String mode) {
        setBusy(true, "Выполняю: " + mode + " ...");
        new Thread(new Runnable() {
            public void run() {
                final String out = runScript(mode);
                ui.post(new Runnable() {
                    public void run() {
                        status.setText(out.length() == 0 ? "пустой ответ скрипта" : out);
                        Toast.makeText(MainActivity.this,
                                "push".equals(mode) ? "Отправлено" : "Загружено",
                                Toast.LENGTH_SHORT).show();
                        refresh();
                    }
                });
            }
        }).start();
    }

    private void setBusy(boolean value, String text) {
        busy = value;
        pushBtn.setEnabled(!value);
        pullBtn.setEnabled(!value);
        settingsBtn.setEnabled(!value);
        if (text != null) {
            info.setText(text);
        }
    }

    private void openSettings() {
        final EditText eServer = new EditText(this);
        eServer.setHint("http://sync.ybx.app");
        eServer.setText(confValue("SERVER"));
        eServer.setInputType(InputType.TYPE_TEXT_VARIATION_URI);

        final EditText eUser = new EditText(this);
        eUser.setHint("пользователь (x-auth-user)");
        eUser.setText(confValue("AUTH_USER"));

        final EditText ePassword = new EditText(this);
        ePassword.setHint("пароль (md5 посчитается автоматически)");
        ePassword.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);

        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 12,
                getResources().getDisplayMetrics());
        box.setPadding(pad, pad, pad, pad);
        box.addView(label("Адрес сервера"));
        box.addView(eServer);
        box.addView(label("Пользователь"));
        box.addView(eUser);
        box.addView(label("Пароль"));
        box.addView(ePassword);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(box);

        new AlertDialog.Builder(this)
                .setTitle("Настройки сервера")
                .setView(scroll)
                .setPositiveButton("Сохранить", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int w) {
                        saveConf(eServer.getText().toString(), eUser.getText().toString(),
                                ePassword.getText().toString());
                        refresh();
                    }
                })
                .setNegativeButton("Отмена", null)
                .show();
    }

    private TextView label(String text) {
        TextView t = new TextView(this);
        t.setText(text);
        t.setTextSize(13);
        t.setPadding(0, 8, 0, 0);
        return t;
    }

    private String confValue(String key) {
        try {
            FileInputStream fis = new FileInputStream(CONF);
            BufferedReader r = new BufferedReader(new InputStreamReader(fis, "UTF-8"));
            String line;
            while ((line = r.readLine()) != null) {
                line = line.trim();
                String prefix = key + "=";
                if (line.startsWith(prefix)) {
                    String v = line.substring(prefix.length()).trim();
                    if (v.length() >= 2 && v.startsWith("\"") && v.endsWith("\"")) {
                        v = v.substring(1, v.length() - 1);
                    } else if (v.length() >= 2 && v.startsWith("'") && v.endsWith("'")) {
                        v = v.substring(1, v.length() - 1);
                    }
                    r.close();
                    return v;
                }
            }
            r.close();
        } catch (Exception ignored) {
        }
        return "";
    }

    private void saveConf(String serverUrl, String user, String password) {
        try {
            File dir = new File(CONF_DIR);
            if (!dir.exists()) {
                dir.mkdirs();
            }
            String key = confValue("AUTH_KEY");
            String pass = clean(password);
            if (pass.length() > 0) {
                key = pass.matches("[0-9a-fA-F]{32}") ? pass.toLowerCase() : md5(pass);
            }
            FileOutputStream fos = new FileOutputStream(CONF);
            fos.write(("SERVER='" + clean(serverUrl) + "'\n").getBytes("UTF-8"));
            fos.write(("AUTH_USER='" + clean(user) + "'\n").getBytes("UTF-8"));
            fos.write(("AUTH_KEY='" + key + "'\n").getBytes("UTF-8"));
            fos.close();
            Toast.makeText(this, "Сохранено", Toast.LENGTH_SHORT).show();
        } catch (Exception ex) {
            Toast.makeText(this, "Не удалось сохранить: " + ex, Toast.LENGTH_LONG).show();
        }
    }

    private String md5(String value) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("MD5");
        byte[] bytes = digest.digest(value.getBytes("UTF-8"));
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < bytes.length; i++) {
            String h = Integer.toHexString(bytes[i] & 0xff);
            if (h.length() == 1) {
                sb.append('0');
            }
            sb.append(h);
        }
        return sb.toString();
    }

    private String clean(String value) {
        return value.replace("'", "").replace("\n", "").trim();
    }
}
