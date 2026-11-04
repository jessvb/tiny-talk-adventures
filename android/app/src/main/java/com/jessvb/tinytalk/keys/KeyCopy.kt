package com.jessvb.tinytalk.keys

/** Settings wording that stays true whether or not this build has a built-in key. */
object KeyCopy {
    fun status(status: KeyStatus): String = status.label

    /** The action that removes the parent's own key. */
    fun clearAction(bakedPresent: Boolean): String =
        if (bakedPresent) "Use built-in key" else "Remove my key"

    fun groqIntro(bakedPresent: Boolean): String =
        if (bakedPresent) {
            "Elsie thinks up the story in the cloud. The app comes with a built-in key; you can use your own instead."
        } else {
            "Elsie thinks up the story in the cloud and needs a key to do it. Add one below."
        }
}
