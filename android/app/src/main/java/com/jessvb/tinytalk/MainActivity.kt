package com.jessvb.tinytalk

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels

class MainActivity : ComponentActivity() {
    /** Owns everything long-lived; survives configuration-change recreation of this activity. */
    private val vm: TinyTalkViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { TinyTalkApp(vm) }
    }

    override fun onStart() {
        super.onStart()
        vm.setForeground(true)
    }

    override fun onStop() {
        super.onStop()
        // A configuration change is not "going to the background": keep the story running.
        if (!isChangingConfigurations) vm.setForeground(false)
    }
}
