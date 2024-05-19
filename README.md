# Glint rendering with normal map filtering for water surface rendering
Supplementary material for Master's Thesis on water surface rendering using glints

Based on the method of Xavier Chermain et al (http://igg.unistra.fr/People/chermain/glint_anti_aliasing/).

## Overview
We proposed a modified V-cavity masking and shadowing function that is compatible with non-centered Beckmann normal distribution.
Using this function we modified the algorithm to use LEADR Mapping (https://inria.hal.science/hal-00858220/en) instead of LEAN Mapping (https://redirect.cs.umbc.edu/~olano/papers/lean/).
This allowed us to calculate accurate projection weights in our BRDF and improve the realism of the resulting picture.

Two implementations are availaible - as a modification to the original authors' prototype and as a patch for Unreal Engine 5.3. Unreal Engine 5.3 already has an implementation for Chermain's algorithm in their Substrate Materials experimental model, which offers a good point of comparison.

## Example
![photo1715519452](https://github.com/YakovDavis/WaterGlints/assets/11318110/4c6ebe40-e263-4a5f-ad43-0baeb9fd5f8b)
Simulated ocean surface rendering using Unreal Engine 5.3 with our modification

## Installation
### A. Chermain's prototype
1. Download and extract the "Code" archive from the website http://igg.unistra.fr/People/chermain/glint_anti_aliasing/
2. Navigate to */stephen_supplemental_material/code* and paste the contents of the ChermainMod folder from this repository
3. Compile the project as usual

### B. Unreal Engine 5.3
1. Acquire access to Unreal Engine repository
2. Clone the 5.3.2-release tag
3. Apply the git patch from the UnrealPatch folder from this repository (copy the patch to the Unreal Engine directory root and run ```git apply 0001-Custom-Glints-for-Unreal-fix-for-stats-command.patch```) 
4. Setup and compile the Engine as usual
5. ATTENTION: the code in the UnrealSrc folder is not the complete code needed for the project and all the parts from the actual Unreal Source are removed. Use the patch to actually install the modification.

## Unreal usage instructions
The patch adds a new Shading model called "Glinty Water", you can use it for a translucent material (set to forward shading surface) to make a glinty material. Substrate Materials must be disabled for this to work. To set up the parameters for our model, use the Material Editor node called "Glinty Water Params". You can find an example of how to set everyithing up in either of the two included demo projects in the UnrealProjects folder.

The WaterSim demo project is based on this repo for Niagara-based ocean simulation (https://github.com/Deathrey/NiagaraOceanTutorial)
