package com.jessvb.tinytalk

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.jessvb.tinytalk.ui.Navigator
import com.jessvb.tinytalk.ui.SharedPrefsConsentStore

class MainActivity : ComponentActivity() {
    private lateinit var navigator: Navigator

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        navigator = Navigator(SharedPrefsConsentStore(this))
        setContent { TinyTalkApp(navigator) }
    }
}
